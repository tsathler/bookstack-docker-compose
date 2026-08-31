# Assistente de IA do BookStack com Gemini API

## Objetivo

Este módulo adiciona uma interface web e um gateway interno de perguntas e respostas sobre as páginas
do BookStack. O modelo é acessado pela Gemini API hospedada; o servidor
local não precisa de GPU e não aceita conexões diretas do chatbot pela internet.

O MVP usa recuperação lexical com SQLite FTS5. Isso reduz dependências, evita
publicar um banco vetorial e permite validar segurança e qualidade antes de
introduzir embeddings. O conteúdo recuperado é enviado ao Google somente durante
uma pergunta.

## Arquitetura e exposição de rede

```text
Cliente -> NGINX:443 -> 127.0.0.1:8000 -> ai_service:8000
                                      -> bookstack:80 (rede Docker)
                                      -> generativelanguage.googleapis.com:443 (saída HTTPS)

MariaDB:3306 e SQLite da IA: somente locais/internos
```

Portas publicadas pelo host:

- `443/tcp`: entrada HTTPS do NGINX.
- `80/tcp`: opcional, para redirect/ACME.
- `127.0.0.1:6875`: BookStack para o NGINX, não para a rede externa.
- `127.0.0.1:8000`: gateway de IA para o NGINX, não para a rede externa.

O serviço `ai_service` não publica Qdrant, MariaDB ou qualquer porta adicional.
A porta Docker interna `8000` existe apenas para comunicação do container e o
binding no host é explicitamente `127.0.0.1`. Não remova esse endereço e não
troque por `0.0.0.0`.

## Pré-requisitos

1. BookStack em execução e acessível na rede Docker.
2. Conta Google AI Studio e uma chave da Gemini API.
3. Um usuário técnico do BookStack com somente leitura e permissão de acesso à API.
4. Docker Compose com capacidade de fazer build local.

## Configuração inicial

Copie o arquivo de ambiente e preencha os valores:

```bash
cp .env.example .env
chmod 600 .env
openssl rand -hex 32
```

Preencha no `.env`:

```env
GEMINI_MODEL=identificador_exato_do_modelo_no_Google_AI_Studio
GEMINI_API_KEY=AIza...
BOOKSTACK_API_TOKEN_ID=...
BOOKSTACK_API_TOKEN_SECRET=...
CHATBOT_ACCESS_TOKEN=valor_gerado_com_openssl
```

Não versione `.env`, tokens ou backups que contenham segredos.

## Criar o token do BookStack

1. Crie um usuário técnico, por exemplo `bookstack-ai`.
2. Atribua uma role somente leitura.
3. Conceda a permissão de acesso à API.
4. Gere um token no BookStack e guarde ID e secret no `.env`.
5. Não conceda permissões de criação, edição, exclusão, administração ou upload.

A API do BookStack respeita as permissões do usuário associado ao token. Mesmo
assim, no MVP recomenda-se indexar apenas livros que todos os usuários do
assistente possam consultar. Indexação com ACL por usuário/grupo será necessária
antes de expor documentos restritos a públicos diferentes.

## Subir o serviço

```bash
docker compose --profile ai build ai_service
docker compose --profile ai up -d bookstack_db bookstack ai_service
docker compose ps
curl -fsS http://127.0.0.1:8000/health
```

O serviço não possui documentação Swagger pública (`/docs` foi desabilitado).

## Indexar páginas

Execute após a instalação e sempre que houver mudanças relevantes no conteúdo:

```bash
chmod +x scripts/reindex_bookstack_ai.sh
./scripts/reindex_bookstack_ai.sh
```

O índice fica em `data/ai/knowledge.db`, protegido pelo `.gitignore`.

Agendamento opcional, depois de validar o processo:

```cron
30 * * * * cd /opt/bookstack && ./scripts/reindex_bookstack_ai.sh >> /var/log/bookstack_ai_reindex.log 2>&1
```

## Testar uma pergunta

Internamente no host:

```bash
curl -sS http://127.0.0.1:8000/chat \
  -H 'Content-Type: application/json' \
  -H 'X-Chatbot-Token: SEU_CHATBOT_ACCESS_TOKEN' \
  -d '{"question":"Como executar o rollback deste serviço?"}'
```

Externamente, a interface fica em `/assistente/` e a API em `/assistente/chat` através do HTTPS do NGINX. A chave
Gemini nunca deve ser enviada pelo cliente.

## Controles de segurança implementados

- Gemini é chamado somente pelo backend; a chave não aparece no navegador.
- A interface cria uma sessão `HttpOnly`, `Secure` e `SameSite=Lax`; a API também aceita `X-Chatbot-Token` para integrações técnicas.
- Limite de 2.000 caracteres por pergunta e 32 KB no NGINX.
- Resposta limitada a 1.200 tokens e timeout de 30 segundos na API.
- Prompt instrui o modelo a usar apenas o contexto e ignorar instruções presentes
  nos documentos, reduzindo risco de prompt injection armazenado.
- Respostas sem documentos relevantes não chamam o modelo.
- Contexto limitado a 18.000 caracteres e no máximo cinco fontes.
- Citações retornam título, ID e URL da página consultada.
- Usuário técnico do BookStack deve ser somente leitura.
- Banco MariaDB e índice SQLite não possuem portas públicas.
- Container do gateway roda como usuário não-root, filesystem read-only e `/tmp`
  em tmpfs.
- Serviço de IA tem healthcheck e logs do Docker com rotação.
- `.env`, tokens, banco SQLite e backups permanecem fora do Git.
- Acesso ao serviço passa pelo NGINX e pela porta HTTPS corporativa.

## Limitações e decisões conscientes

### Dados enviados à Gemini API

Os trechos recuperados das páginas são enviados para a API externa do Google.
Isso é adequado somente após aprovação da política corporativa de dados e dos
termos aplicáveis. Não indexe segredos, senhas, chaves, dados pessoais ou
documentos restritos sem autorização.

### Identidade e ACL

O login atual usa um token de aplicação convertido em sessão HTTPOnly; ele não é
uma identidade individual. O MVP não consegue aplicar permissões diferentes por
usuário final. Por isso, use somente um conjunto de documentos com a mesma
classificação de acesso. A próxima evolução deve integrar SSO/LDAP/OIDC no
gateway e manter ACL por grupo no índice.

### Confiabilidade da API gratuita

Endpoints de prototipação podem ter limites, alterações de modelo e indisponibilidade.
Configure timeout, retry limitado e uma mensagem de indisponibilidade no cliente.
Não use o endpoint gratuito como único componente de um processo crítico.

## Operação e resposta a incidentes

- Revogue e substitua `GEMINI_API_KEY`, tokens BookStack e
  `CHATBOT_ACCESS_TOKEN` imediatamente após suspeita de exposição.
- Verifique `docker compose logs --tail=100 ai_service` sem registrar prompts.
- Reindexe após revogar documentos ou alterar a role técnica.
- Faça backup de `data/ai/knowledge.db` junto com o backup da aplicação, avaliando
  a classificação dos documentos armazenados.
- Para desligar o recurso: `docker compose stop ai_service` e remova a rota
  `/assistente/` do NGINX antes de recarregá-lo.

## Próximas evoluções recomendadas

1. Autenticação individual via SSO/LDAP.
2. ACL por livro/grupo no índice.
3. Embeddings e busca híbrida lexical + semântica.
4. Métricas de latência, erros e custo sem armazenar conteúdo sensível.
5. Testes de avaliação com perguntas esperadas e casos de prompt injection.
6. Fallback controlado para outro provedor ou modelo local aprovado.
