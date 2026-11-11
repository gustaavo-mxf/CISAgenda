
import process from 'node:process';

process.loadEnvFile('.env');

const key = process.env.NVIDIA_API_KEY?.trim();

if (!key) {
  throw new Error('NVIDIA_API_KEY não encontrada no .env');
}

console.log('Testando NVIDIA com parâmetros oficiais...');

try {
  const response = await fetch(
    'https://integrate.api.nvidia.com/v1/chat/completions',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify({
        model: 'openai/gpt-oss-20b',
        messages: [
          {
            role: 'user',
            content: 'Responda somente: NVIDIA OK'
          }
        ],
        temperature: 1,
        top_p: 1,
        max_tokens: 4096,
        stream: false
      }),
      signal: AbortSignal.timeout(120000)
    }
  );

  console.log('HTTP STATUS:', response.status);

  const result = await response.text();

  if (!response.ok) {
    console.log('ERRO:', result);
  } else {
    const data = JSON.parse(result);
    console.log('RESPOSTA:', data.choices?.[0]?.message?.content);
  }

} catch (error) {
  console.log('FALHA:', error.name);
  console.log('MENSAGEM:', error.message);
}

console.log('Diagnóstico concluído.');
