# CIS Agenda

Repositório com o backend experimental do Telegram e o esquema SQL do Supabase.

O backend incluído neste pacote é a versão NVIDIA NIM presente no ZIP enviado. Ele não é a versão posterior que utiliza OpenRouter e consulta especialidades no Supabase.

## Execução

Copie `backend/.env.example` para `backend/.env` e configure as credenciais localmente. Na pasta `backend`, execute `npm run dev`.

## Banco de dados

O arquivo `database/supabase_schema.sql` contém a estrutura do banco de dados, não os registros de pacientes. Confira o esquema antes de executá-lo em um projeto existente.

## Segurança

Não publique arquivos `.env`, tokens, chaves secretas ou dados reais de pacientes. O bot é experimental e não deve ser utilizado para atendimento real sem controles adicionais.
