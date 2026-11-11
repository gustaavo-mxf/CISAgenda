import { createServer } from 'node:http'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

function loadEnvFile() {
  const here = dirname(fileURLToPath(import.meta.url))
  const envPath = [join(here, '..', '.env'), '.env'].find((p) => existsSync(p))
  if (!envPath) return
  const lines = readFileSync(envPath, 'utf8').replace(/^﻿/, '').split(/\r?\n/)
  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const index = trimmed.indexOf('=')
    if (index < 1) continue
    const key = trimmed.slice(0, index).trim()
    let value = trimmed.slice(index + 1).trim()
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1)
    }
    if (!(key in process.env)) process.env[key] = value
  }
}
loadEnvFile()

const telegramToken = process.env.TELEGRAM_BOT_TOKEN?.trim()
const nvidiaKey = process.env.NVIDIA_API_KEY?.trim()
const nvidiaBaseUrl = (process.env.NVIDIA_BASE_URL || 'https://integrate.api.nvidia.com/v1').replace(/\/$/, '')
const nvidiaModel = process.env.NVIDIA_MODEL || 'openai/gpt-oss-20b'
const port = Number(process.env.PORT || 3001)
const nvidiaMaxTokens = Number(process.env.NVIDIA_MAX_TOKENS || 1500)
const nvidiaTimeoutMs = Number(process.env.NVIDIA_TIMEOUT_MS || 90_000)
const telegramBase = (process.env.TELEGRAM_API_BASE || 'https://api.telegram.org').replace(/\/$/, '')

function fatal(message) {
  console.error(`\nERRO DE CONFIGURAÇÃO: ${message}\n`)
  process.exit(1)
}
if (!telegramToken) fatal('configure TELEGRAM_BOT_TOKEN no arquivo backend/.env.')
if (!nvidiaKey) fatal('configure NVIDIA_API_KEY no arquivo backend/.env.')
if (!Number.isInteger(port) || port < 1 || port > 65535) fatal('PORT inválida.')
if (!Number.isFinite(nvidiaMaxTokens) || nvidiaMaxTokens < 100) fatal('NVIDIA_MAX_TOKENS inválido.')
if (!Number.isFinite(nvidiaTimeoutMs) || nvidiaTimeoutMs < 1000) fatal('NVIDIA_TIMEOUT_MS inválido.')

const telegramApi = `${telegramBase}/bot${telegramToken}`
const history = new Map()
const requestTimes = new Map()
const MAX_HISTORY = 8
const MAX_MESSAGE_LENGTH = 1800
const HISTORY_TTL_MS = 30 * 60 * 1000
let updateOffset = 0
let running = true

const SYSTEM_PROMPT = `Você é o assistente informativo experimental do CIS Agenda, em português do Brasil.
Seu escopo é EXCLUSIVAMENTE administrativo: explicar em termos gerais que a pessoa preenche o formulário de sua especialidade, a equipe analisa a solicitação e, se houver disponibilidade, a equipe envia uma proposta de horário.
Regras obrigatórias:
- Não faça triagem, avaliação clínica, diagnóstico, prognóstico ou recomendação de tratamento/medicamento.
- Não classifique urgência, prioridade, elegibilidade, fila ou disponibilidade.
- Não invente horários, prazos, endereço, telefone, documentos necessários, preços ou links.
- Não afirme que consultou cadastro, solicitação, agenda ou proposta; este protótipo não está conectado ao banco do CIS.
- Não confirme, recuse nem cancele agendamentos. Explique que essas ações ainda precisam ser feitas pela equipe.
- Não solicite CPF, documentos, endereço, telefone ou detalhes de saúde.
- Para assuntos clínicos ou pessoais, oriente a pessoa a falar diretamente com a equipe do CIS. Em situação de perigo imediato, recomende procurar o serviço de emergência local.
- Seja cordial, objetivo e deixe claro quando não souber algo.`

function normalize(value) {
  return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
}

function containsPersonalOrClinicalContent(text) {
  const t = normalize(text)
  const clinicalTerms = /\b(dor|dores|febre|tosse|sangue|sangramento|tontura|remedio|medicamento|diagnostico|sintoma|sintomas|doenca|tratamento|cirurgia|exame|pressao alta|diabetes|ansiedade|depressao|ferida|machucado|inchaco|enjoo|vomito|alergia|gravidez|gestante|urgente|emergencia)\b/.test(t)
  const personalTerms = /\b(cpf|rg|nascimento|endereco|meu telefone|meu celular|meu email|meu e-mail)\b/.test(t)
  const email = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.test(text)
  const cpf = /\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/.test(text)
  const phone = /(?:\+?55\s?)?(?:\(?\d{2}\)?\s?)?9?\d{4}[-.\s]?\d{4}/.test(text)
  return clinicalTerms || personalTerms || email || cpf || phone
}

function purgeExpiredMemory() {
  const now = Date.now()
  for (const [userId, entries] of history) {
    const active = entries.filter((entry) => now - entry.at < HISTORY_TTL_MS)
    if (active.length) history.set(userId, active)
    else history.delete(userId)
  }
  for (const [userId, times] of requestTimes) {
    const recent = times.filter((time) => now - time < 60_000)
    if (recent.length) requestTimes.set(userId, recent)
    else requestTimes.delete(userId)
  }
}

function isRateLimited(userId) {
  const now = Date.now()
  const recent = (requestTimes.get(userId) || []).filter((time) => now - time < 60_000)
  if (recent.length >= 12) {
    requestTimes.set(userId, recent)
    return true
  }
  recent.push(now)
  requestTimes.set(userId, recent)
  return false
}

function getFormLinks() {
  const candidates = [
    { label: 'Fisioterapia', url: process.env.FORM_URL_FISIO?.trim() || '' },
    { label: 'Nutrição', url: process.env.FORM_URL_NUTRI?.trim() || '' },
    { label: 'Enfermagem', url: process.env.FORM_URL_ENF?.trim() || '' },
  ]
  return candidates.filter(({ url }) => {
    try { return new URL(url).protocol === 'https:' } catch { return false }
  })
}

async function telegram(method, body, timeoutMs = 15_000) {
  const response = await fetch(`${telegramApi}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  })
  const data = await response.json().catch(() => ({}))
  if (!response.ok || !data.ok) {
    throw new Error(`Telegram ${method} falhou (HTTP ${response.status}): ${data.description || 'erro sem descrição'}`)
  }
  return data.result
}

async function sendText(chatId, text, extra = {}) {
  return telegram('sendMessage', { chat_id: chatId, text: text.slice(0, 4000), ...extra })
}

async function sendForms(chatId) {
  const links = getFormLinks()
  if (links.length === 0) {
    await sendText(chatId, 'Os links oficiais dos formulários ainda não foram configurados neste bot. Entre em contato diretamente com a equipe do CIS para receber o formulário correto.')
    return
  }
  const keyboard = {
    inline_keyboard: links.map(({ label, url }) => [{ text: `Formulário — ${label}`, url }]),
  }
  await sendText(chatId, 'Selecione a especialidade para abrir o formulário oficial configurado:', { reply_markup: keyboard })
}

function extractText(content) {
  const raw = Array.isArray(content)
    ? content.map((part) => (typeof part === 'string' ? part : part?.text ?? '')).join('')
    : typeof content === 'string' ? content : ''
  return raw.replace(/<think>[\s\S]*?<\/think>/gi, '').trim()
}

async function askNvidia(userId, text) {
  const now = Date.now()
  const previous = (history.get(userId) || []).filter((entry) => now - entry.at < HISTORY_TTL_MS).slice(-MAX_HISTORY)
  const messages = [
    { role: 'system', content: SYSTEM_PROMPT },
    ...previous.map(({ role, content }) => ({ role, content })),
    { role: 'user', content: text },
  ]

  let answer = ''
  let maxTokens = nvidiaMaxTokens
  let lastError = null
  for (let attempt = 1; attempt <= 3 && !answer; attempt++) {
    try {
      const response = await fetch(`${nvidiaBaseUrl}/chat/completions`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${nvidiaKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ model: nvidiaModel, messages, temperature: 0.25, max_tokens: maxTokens, stream: false }),
        signal: AbortSignal.timeout(nvidiaTimeoutMs),
      })
      if (!response.ok) {
        const detail = (await response.text().catch(() => '')).slice(0, 300).replace(/\s+/g, ' ')
        console.error(`Falha NVIDIA (HTTP ${response.status}) na tentativa ${attempt}: ${detail}`)
        lastError = new Error(`NVIDIA respondeu com HTTP ${response.status}`)
        if (response.status === 429 || response.status >= 500) {
          await new Promise((resolve) => setTimeout(resolve, 1500 * attempt))
          continue
        }
        break // 400/401/403/404: repetir não resolve
      }
      const payload = await response.json()
      const choice = payload.choices?.[0]
      answer = extractText(choice?.message?.content)
      if (!answer) {
        console.error(`NVIDIA retornou resposta vazia (finish_reason=${choice?.finish_reason ?? 'desconhecido'}) com max_tokens=${maxTokens}.`)
        lastError = new Error('A NVIDIA não retornou texto.')
        if (choice?.finish_reason === 'length') maxTokens = Math.min(maxTokens * 2, 4096)
      }
    } catch (error) {
      lastError = error
      console.error(`Erro ao chamar a NVIDIA na tentativa ${attempt}: ${error instanceof Error ? error.message : 'erro desconhecido'}`)
    }
  }
  if (!answer) throw lastError ?? new Error('A NVIDIA não retornou texto.')

  history.set(userId, [
    ...previous,
    { role: 'user', content: text, at: now },
    { role: 'assistant', content: answer, at: Date.now() },
  ].slice(-MAX_HISTORY))
  return answer
}

async function handleMessage(message) {
  if (!message?.chat?.id) return
  const chatId = message.chat.id
  const userId = message.from?.id ?? chatId
  if (typeof message.text !== 'string') {
    await sendText(chatId, 'Por enquanto, consigo responder apenas mensagens de texto. Não envie documentos, dados pessoais ou informações clínicas.')
    return
  }

  const text = message.text.trim()
  if (!text) return
  if (isRateLimited(userId)) {
    await sendText(chatId, 'Você enviou muitas mensagens em pouco tempo. Aguarde um minuto e tente novamente.')
    return
  }
  if (text.length > MAX_MESSAGE_LENGTH) {
    await sendText(chatId, 'Sua mensagem é muito longa. Envie uma dúvida administrativa mais curta, por favor.')
    return
  }

  if (text.startsWith('/start')) {
    await sendText(chatId,
      'Olá! Sou o assistente experimental do CIS Agenda. Posso explicar o fluxo administrativo e mostrar os formulários configurados.\n\n' +
      'Use /formularios para abrir um formulário ou /ajuda para ver os comandos.\n\n' +
      'Atenção: este bot ainda não consulta a agenda nem confirma/cancela horários. Não envie CPF, documentos, telefone ou informações clínicas.'
    )
    return
  }
  if (text.startsWith('/ajuda') || text.startsWith('/help')) {
    await sendText(chatId, 'Comandos disponíveis:\n/start — iniciar conversa\n/ajuda — mostrar esta ajuda\n/formularios — abrir os formulários oficiais configurados\n/humano — informações para procurar a equipe\n\nPara dúvidas administrativas gerais, basta escrever uma mensagem. Não envie informações pessoais ou clínicas.')
    return
  }
  if (text.startsWith('/formularios')) {
    await sendForms(chatId)
    return
  }
  if (text.startsWith('/humano')) {
    await sendText(chatId, 'Este protótipo ainda não tem encaminhamento automático para a equipe. Entre em contato diretamente com o CIS pelos canais oficiais que você já utiliza.')
    return
  }

  const t = normalize(text)
  if (/\b(confirmar|confirma|recusar|recuso|cancelar|cancela|desmarcar|minha proposta|meu horario|minha consulta)\b/.test(t)) {
    await sendText(chatId, 'Ainda não estou conectado ao banco de agenda do CIS. Por isso, não consigo consultar, confirmar, recusar ou cancelar propostas. Procure a equipe do CIS para verificar sua situação. Nenhuma alteração foi feita.')
    return
  }
  if (containsPersonalOrClinicalContent(text)) {
    await sendText(chatId, 'Por segurança, este bot não recebe nem analisa dados pessoais ou informações clínicas. Não envie documentos, CPF, telefone ou detalhes de saúde. Para tratar desse assunto, fale diretamente com a equipe do CIS. Se houver perigo imediato, procure o serviço de emergência local.')
    return
  }
  if (/\b(formulario|formularios|solicitar atendimento|quero atendimento|agendar|marcar atendimento)\b/.test(t)) {
    await sendForms(chatId)
    return
  }

  try {
    await telegram('sendChatAction', { chat_id: chatId, action: 'typing' })
    const answer = await askNvidia(userId, text)
    await sendText(chatId, answer)
  } catch (error) {
    console.error('Erro ao responder mensagem:', error instanceof Error ? error.message : 'erro desconhecido')
    await sendText(chatId, 'No momento não consegui consultar o assistente de dúvidas. Tente novamente mais tarde ou fale diretamente com a equipe do CIS.')
  }
}

async function pollingLoop() {
  while (running) {
    try {
      const updates = await telegram('getUpdates', {
        offset: updateOffset,
        timeout: 25,
        allowed_updates: ['message'],
      }, 35_000)
      purgeExpiredMemory()
      for (const update of updates) {
        updateOffset = Math.max(updateOffset, update.update_id + 1)
        try {
          await handleMessage(update.message)
        } catch (error) {
          console.error('Falha ao processar atualização do Telegram:', error instanceof Error ? error.message : 'erro desconhecido')
        }
      }
    } catch (error) {
      if (running) {
        const message = error instanceof Error ? error.message : 'erro desconhecido'
        console.error('Falha no polling do Telegram:', message)
        if (message.includes('HTTP 409')) {
          console.error('DICA: feche os outros terminais/processos que executam este bot; só uma instância pode receber mensagens por vez.')
        }
        await new Promise((resolve) => setTimeout(resolve, 3000))
      }
    }
  }
}

async function startTelegram() {
  let me
  try {
    me = await telegram('getMe', {})
  } catch (error) {
    const message = error instanceof Error ? error.message : 'erro desconhecido'
    console.error(`Não foi possível validar o token do Telegram: ${message}`)
    if (message.includes('HTTP 401') || message.includes('HTTP 404')) {
      fatal('o TELEGRAM_BOT_TOKEN está incorreto. Copie novamente o token do @BotFather (sem aspas e sem espaços).')
    }
    console.error('Sem conexão com o Telegram agora; tentando iniciar mesmo assim.')
  }
  if (me) console.log(`Bot conectado como @${me.username}.`)
  try {
    await telegram('deleteWebhook', { drop_pending_updates: false })
  } catch (error) {
    console.error('Não foi possível remover webhook antigo:', error instanceof Error ? error.message : 'erro desconhecido')
  }
}

const server = createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' })
    res.end(JSON.stringify({ ok: true, service: 'cis-agenda-telegram-bot' }))
    return
  }
  res.writeHead(404, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify({ ok: false, error: 'not_found' }))
})

async function shutdown(signal) {
  if (!running) return
  console.log(`Recebido ${signal}; encerrando bot.`)
  running = false
  server.close()
  process.exit(0)
}

process.once('SIGINT', () => void shutdown('SIGINT'))
process.once('SIGTERM', () => void shutdown('SIGTERM'))

server.on('error', (error) => {
  if (error.code === 'EADDRINUSE') fatal(`a porta ${port} já está em uso. Feche o outro terminal que executa o bot ou mude PORT no .env.`)
  fatal(`falha ao abrir a porta ${port}: ${error.message}`)
})

server.listen(port, async () => {
  console.log(`Health check disponível na porta ${port}.`)
  await startTelegram()
  try {
    await telegram('setMyCommands', {
      commands: [
        { command: 'start', description: 'Iniciar conversa' },
        { command: 'ajuda', description: 'Ver comandos e orientações' },
        { command: 'formularios', description: 'Abrir formulários do CIS' },
        { command: 'humano', description: 'Como falar com a equipe' },
      ],
    })
    console.log('Comandos do bot registrados no Telegram.')
  } catch (error) {
    console.error('Não foi possível registrar a lista de comandos:', error instanceof Error ? error.message : 'erro desconhecido')
  }
  void pollingLoop()
})
