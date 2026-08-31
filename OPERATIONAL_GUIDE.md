# 📘 Guia Operacional Pós-Instalação: BookStack Corporativo

Este documento reúne os procedimentos operacionais, políticas de segurança, mapeamento de permissões e rotinas de manutenção para sustentação do **BookStack** em ambiente corporativo.

---

## 1. 👥 Mapeamento de Grupos do Active Directory (AD Group Mapping)

O BookStack permite que os grupos de segurança do Active Directory (`memberOf`) sejam mapeados diretamente para as **Roles (Funções/Papéis)** do sistema. A sincronização ocorre **automaticamente no momento em que o usuário faz login**.

### 1.1. Estrutura Recomendada de Grupos no Active Directory

Crie no seu AD (por exemplo, na OU `OU=Grupos,OU=TI,DC=empresa,DC=local`) os seguintes grupos:

| Grupo no Active Directory | Perfil no BookStack | Descrição das Permissões |
| :--- | :--- | :--- |
| `GG_TI_Admins` | **Admin** | Acesso total ao sistema, configurações, gerenciamento de usuários e roles. |
| `GG_TI_N3_Engenharia` | **Editor Técnico N3** | Criação e exclusão de Livros/Capítulos/Páginas, gerenciamento de permissões de livros. |
| `GG_TI_N2_Suporte` | **Editor Técnico N2** | Criação e edição de POPs e páginas, upload de anexos e diagramas. |
| `GG_TI_N1_ServiceDesk`| **Leitor / Editor N1** | Leitura de toda a documentação, criação de comentários e edição de páginas específicas. |
| `GG_TI_Auditores` | **Visualizador / Auditor** | Acesso de apenas leitura a livros públicos e POPs, sem permissão de edição. |

---

### 1.2. Passo a Passo para Configurar o Mapeamento na Interface Web

1. Acesse o BookStack com um usuário com privilégios de **Admin** (ex: conta local ou o primeiro admin autenticado).
2. No menu superior direito, clique em **Configurações (Settings)** ⚙️ -> **Funções (Roles)**.
3. Para cada Role que deseja mapear:
   - Clique em **Editar** na Role (ou crie uma nova Role caso deseje perfis customizados).
   - Localize o campo **IDs de Autenticação Externa (External Authentication IDs)**.
   - Insira o nome do grupo do Active Directory.
     > **Dica:** É recomendável preencher tanto o **Short Name (sAMAccountName)** quanto o **DN Completo** (um por linha):
     ```text
     GG_TI_Admins
     CN=GG_TI_Admins,OU=Grupos,OU=TI,DC=empresa,DC=local
     ```
   - Clique em **Salvar Função (Save Role)**.

![Configuração de Roles](https://raw.githubusercontent.com/BookStackApp/BookStack/develop/resources/lang/en/illustrations/books.png)

### 1.3. Regras de Sincronização e Manutenção

- **Adição automática:** Quando um usuário autentica via LDAP, o BookStack consulta seus grupos (`memberOf`) e atribui as Roles correspondentes.
- **Remoção de Roles (`LDAP_REMOVE_FROM_GROUPS`):**
  - Se configurado como `true` no `.env`, caso o usuário seja removido de um grupo no AD, a Role correspondente será revogada no próximo login.
  - Se configurado como `false`, Roles atribuídas manualmente no BookStack não são removidas pela sincronização.

---

## 2. 🚨 Gestão da Conta Local de Emergência (Break-Glass Account)

Mesmo com a autenticação via Active Directory/LDAP ativada (`AUTH_METHOD=ldap`), o BookStack **mantém ativa a capacidade de autenticar contas locais** cadastradas diretamente na base de dados com e-mail e senha.

### 2.1. Política de Break-Glass
- A conta local primária (ex: `admin@empresa.com.br` ou `breakglass_admin@empresa.local`) deve ter sua senha armazenada no **Cofre de Senhas Corporativo** (ex: Vault, CyberArk ou Bitwarden Enterprise).
- Esta conta deve ser utilizada exclusivamente em cenários de contingência:
  1. Indisponibilidade total dos Controladores de Domínio (DCs do AD).
  2. Perda de conectividade com a porta 636/389.
  3. Falhas de expiração da Service Account (`svc_bookstack`).

### 2.2. Como Criar ou Redefinir um Administrador Local via Linha de Comando (CLI)

Se todas as credenciais do AD falharem e a senha da conta local tiver sido esquecida, você pode criar instantaneamente um novo Administrador local executando dentro do container:

```bash
# Executar comando artisan dentro do container BookStack
docker exec -it bookstack_app php /app/www/artisan bookstack:create-admin
```

O utilitário interativo solicitará:
1. **Nome do Usuário:** `Administrador Emergencial`
2. **E-mail:** `admin.emergencia@empresa.local`
3. **Senha:** `[Digite uma senha de alta entropia]`

Após a criação, acesse a página de login do BookStack e insira o e-mail e a senha cadastrados.

---

## 3. 🔄 Procedimento Seguro de Atualização da Stack

O BookStack e o MariaDB devem ser atualizados regularmente para recebimento de patches de segurança e novas funcionalidades.

### 3.1. Pré-Requisitos para Atualização
- Agendar janela de manutenção caso o ambiente seja crítico.
- Notificar os usuários da indisponibilidade temporária (1 a 3 minutos).

### 3.2. Passo a Passo de Atualização

1. **Acesse o servidor host:**
   ```bash
   cd /opt/bookstack
   ```

2. **Execute um Backup Manual Preventivo:**
   ```bash
   sudo ./scripts/backup_bookstack.sh
   ```
   > Confirme se o arquivo `.tar.gz` e `.sha256` foram gerados com sucesso antes de prosseguir!

3. **Baixe as imagens aprovadas definidas no ambiente:**
   ```bash
   docker compose pull bookstack_db bookstack
   ```

4. **Recrie os containers com as novas imagens:**
   ```bash
   docker compose up -d
   ```
   > Valide a versão da imagem e tenha um backup íntegro antes de aplicar a mudança. O container executa a inicialização e as migrações necessárias conforme a versão suportada.

5. **Acompanhe os logs da inicialização:**
   ```bash
   docker compose logs -f bookstack
   ```
   Aguarde até a mensagem: `[custom-init] ... done` ou logs de inicialização do NGINX/PHP-FPM.

6. **Validação:**
   Acesse a URL `https://docs.empresa.com.br` e verifique a versão em **Configurações**.

---

## 4. 💾 Rotina de Backup e Disaster Recovery

### 4.1. Configuração do Agendamento Diário (Cron)

Edite a crontab do usuário root no host Linux:
```bash
sudo crontab -e
```

Adicione a linha para execução todos os dias às **02:00 da madrugada**:
```cron
# Backup diário do BookStack com retenção de 15 dias e log
0 2 * * * /opt/bookstack/scripts/backup_bookstack.sh >> /var/log/bookstack_backup.log 2>&1
```

Crie o arquivo de log inicial com permissões adequadas:
```bash
sudo touch /var/log/bookstack_backup.log
sudo chmod 640 /var/log/bookstack_backup.log
```

### 4.2. Simulação e Teste de Restauração

Para restaurar o BookStack em caso de desastre (ex: falha de hardware ou corrupção):
```bash
cd /opt/bookstack
sudo ./scripts/restore_bookstack.sh /var/backups/bookstack/bookstack_backup_YYYYMMDD_HHMMSS.tar.gz
```

---

## 5. 🛠️ Resolução de Incidentes Comuns (Troubleshooting)

### 5.1. Erro `LDAP: Could not bind to LDAP server` / Falha de Conexão
- **Sintoma:** Usuários não conseguem logar com suas credenciais do AD.
- **Causa:** Service account expirada, senha errada ou bloqueio de rede na porta 636.
- **Diagnóstico:**
  ```bash
  # Testar conectividade TCP na porta 636 a partir do host
  nc -zv dc01.empresa.local 636
  
  # Inspecionar logs da aplicação
  docker compose logs bookstack | grep -i ldap
  ```
- **Solução:** Verifique no `.env` se `LDAP_DN` e `LDAP_PASS` estão corretos. Se estiver utilizando LDAPS com certificado interno autoassinado e ocorrer erro de handshake, teste temporariamente `LDAP_TLS_INSECURE=true`.

---

### 5.2. Erro `413 Request Entity Too Large` durante Upload de PDFs / Anexos
- **Sintoma:** O usuário tenta anexar um arquivo de 50MB e recebe erro 413 ou falha no upload.
- **Causa:** Descompasso entre NGINX e PHP.
- **Solução:**
  1. No NGINX (`/etc/nginx/sites-available/bookstack.conf`), garanta `client_max_body_size 100M;`.
  2. No `.env`, confirme `FILE_UPLOAD_LIMIT=100`.
  3. No `custom-php/php-custom.ini`, confirme `upload_max_filesize = 100M` e `post_max_size = 105M`.
  4. Recarregue o NGINX (`sudo systemctl reload nginx`) e reinicie o container (`docker compose restart bookstack`).

---

### 5.3. Erro de CSRF Token Mismatch ou Loops de Redirecionamento
- **Sintoma:** Ao clicar em login ou submeter formulários, o usuário é deslogado ou recebe erro 419 (Page Expired).
- **Causa:** O NGINX não está repassando o cabeçalho `X-Forwarded-Proto https` ou a variável `APP_URL` no `.env` está sem `https://`.
- **Solução:**
  1. Verifique se `APP_URL=https://docs.empresa.com.br` (com `https://` exato).
  2. Verifique se o bloco NGINX possui:
     ```nginx
     proxy_set_header X-Forwarded-Proto $scheme;
     proxy_set_header Host $http_host;
     ```
