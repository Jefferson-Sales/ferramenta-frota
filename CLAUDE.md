# Ferramenta da Frota — contexto do projeto

## O que é

Uma ferramenta web (HTML/JS estático + Supabase como backend) para profissionalizar a gestão da frota da Beep Saúde, substituindo controles que hoje vivem em planilhas Excel/Pipefy/Metabase. Cobre 5 módulos: **Gestão da Frota** (veículos, hubs, contratos), **Manutenções** (ordens de serviço), **Multas**, **Financeiro** (fornecedores, notas fiscais) e **Carros Elétricos** (recargas, telemetria). Usuário principal: Jefferson Sales (Coordenador de Frota, admin), com acesso ampliado a outras pessoas do time por módulo.

## Infraestrutura

- **Repo:** GitHub `Jefferson-Sales/ferramenta-frota` — público (necessário para GitHub Pages grátis; seguro porque só a URL e a chave pública/anon do Supabase ficam no cliente, nada sensível).
- **Deploy:** GitHub Pages, https://jefferson-sales.github.io/ferramenta-frota/ — republica automaticamente 1-2 min após push na branch publicada. Arquivo principal: `index.html` (tudo em um arquivo — HTML/CSS/JS).
- **Backend:** Supabase, projeto `efmpzjkqiwyuumaoumof` ("Central-Frota").
- Importante: a primeira versão rodou como Artifact do Claude, mas foi migrada porque artifacts bloqueiam `fetch`/XHR para domínios externos — nunca conseguiriam falar com o Supabase.

### Problemas de configuração já resolvidos (não repetir)
1. **Link de convite por e-mail quebrado** (apontava pra `localhost`) → corrigir Site URL/Redirect URLs em Authentication → URL Configuration.
2. **"email rate limit exceeded"** ao convidar usuário → plano grátis do Supabase tem limite baixo sem SMTP próprio. Contornado criando usuário direto (Add user → Create new user, com senha e "Auto Confirm User").
3. **Perfil não carregava ("Sem Perfil") mesmo com RLS certo** → faltavam `GRANT` de Postgres pros papéis `anon`/`authenticated` no schema customizado `frota` (schema fora do `public` não recebe isso automaticamente, é independente do RLS). Rodar os `GRANT ... ON SCHEMA frota` / `ALTER DEFAULT PRIVILEGES` se isso voltar a acontecer num schema novo.
4. **`DROP TABLE`/`DROP POLICY` via MCP do Supabase travam** (timeout ~180s) sem motivo aparente — `CREATE`, `ALTER`, `SELECT` funcionam normal. Para redefinir uma policy, usar `ALTER POLICY nome ON tabela USING (...)` em vez de `DROP` + `CREATE`.
5. **Edge Function dava "Failed to fetch" no browser** → `verify_jwt: true` na plataforma bloqueava o preflight CORS (requisição `OPTIONS` sem header `Authorization`). Resolvido com `verify_jwt: false` + validação própria dentro da function.

## Schema / banco de dados

Schema `frota` no Postgres do Supabase (migration fundacional em `claude/schema-fundacao-painel-gestao-2026-10-09.sql` no projeto Claude — não reproduzida aqui por completo, consultar lá ou direto no Supabase). Estrutura:

- **Núcleo:** `hubs`, `fornecedores`, `motoristas`, `veiculos`, `contratos` (+ view `v_contratos_vencendo`, `v_cadastro_frota`, `v_pool_km_contrato` para franquia de km em modo pool).
- **Utilização:** `rotas_realizadas`, `planejamento_picos`.
- **Manutenção:** `oficinas` (com `telefone`, `endereco`, `cnpj` — CNPJ salvo só com dígitos; adicionados em 21/10/2026), `ordens_servico` (enum `status_os` é um fluxo de fases: `agendada` → `aguardando_agendamento` → `aguardando_orcamento` → `em_execucao` → `aguardando_peca` → `aguardando_pagamento` → `concluida`/`cancelada` — valores antigos do enum como `aberta`/`em_reparo` ainda existem no tipo Postgres por não poderem ser removidos, mas não são mais usados em lugar nenhum), `os_pecas`, `os_anexos` (+ bucket Storage privado `os-anexos`), `checklist_padrao_tipo`, `os_checklist_itens`, `revisoes_preventivas`, `checklists` + views de SLA/ranking.
- **Multas:** `multas` (muitos campos de fluxo: identificação, valores, prazos, pessoas/liderança, status) + view `v_multas_detalhe`.
- **Financeiro:** `categorias_custo`, `notas_fiscais` + view `v_fornecedores_nota_atrasada`.
- **Carros Elétricos:** `recargas_eletricas`, `telemetria_diaria`, `parametros_combustao_equivalente`.
- **Controle de acesso:** `usuarios_perfil` com `papel` (admin/operador/visualizador) + `modulos_visualizacao` e `modulos_operador` (arrays de texto). Função `frota.posso_ver(modulo)` (security definer) decide RLS de SELECT por módulo; admin vê tudo. Todas as 18 tabelas do schema têm RLS habilitado. Views importantes usam `security_invoker = true` para herdar o RLS do usuário logado, não do dono da view — seguir esse padrão em views novas.

## Módulos já construídos e status

| Módulo | Status | Observações |
|---|---|---|
| **Gestão da Frota** | CRUD completo (criar + editar) de Veículos, Hubs, Contratos | View `v_cadastro_frota` calcula km excedente, dias restantes, status de contrato. Vínculo placa↔contrato feito via planilha "Beep Frota 2026" (399/403 veículos). Franquia de km é modo **Pool** (soma por contrato, não por veículo) para a maioria dos contratos — usar `v_pool_km_contrato`, não o cálculo individual antigo. |
| **Manutenções (OS)** | Completo, com anexos, checklist por tipo, SLA por oficina, ranking de quebras, custo por veículo/oficina | Trigger sincroniza status do veículo com a OS. |
| **Multas** | Fase 1 only: dados estruturados + CRUD/UI. **Dashboard analítico (ranking de infratores, pontuação CNH, custo mensal) foi deliberadamente deixado para fase 2** — não iniciar sem o Jefferson pedir de novo. Pré-requisito faltante: vincular `motorista_identificado_id` nas multas antigas (hoje o nome só está em texto livre em `descricao`). |
| **Financeiro** | Listagem + **apenas criação** de Fornecedores e Notas Fiscais (só `POST`; sem editar/excluir no front) | — |
| **Carros Elétricos** | Listagem + **apenas criação** de Recargas (só `POST`) + sincronização automática de telemetria via API Questar/Exodus (Edge Function `sync-telemetria-questar`, cron diário 02:00 BRT); no front, card "Telemetria dos elétricos" com botões de diagnóstico e sync manual (texto da tela ainda diz "Integração em teste" — desatualizado) | Dados de energia (kWh/km) não vêm da Questar — o fator fixo 0,10 kWh/km existe só no backend. **Comparação de custo/impacto vs. combustão não está implementada no front** (a descrição do painel promete, mas só há a tabela de recargas; `parametros_combustao_equivalente` não é usada no `index.html`). |
| **Motoristas** | Cadastro importado (506 motoristas únicos) | Ver seção de PII abaixo — acesso restrito. |

### Qualidade de dados — padrões para ficar de olho em novos imports
- Valores em R$ às vezes vêm como **texto** em vez de número (ex. `"R$ 1.160,00"`) — normalizar antes de inserir.
- Erros de fórmula do Excel (`#VALUE!`, `#REF!`) aparecem em imports — tratar como NULL, não travar o import.
- CPFs/placas duplicados por recadastro — preferir o registro com mais campos preenchidos, não o mais recente por padrão.

## Convenções

- **PII de motoristas é sensível** (CPF, RG, CNH, data de nascimento, senha de abastecimento): a tabela `frota.motoristas` só pode ser lida por `admin`. Para telas que só precisam listar/selecionar um motorista (ex. formulário de Multas), usar a view `frota.v_motoristas_basico` (sem dados sensíveis), nunca a tabela bruta. **Nunca armazenar link direto para foto/scan de CNH de terceiros** (links assinados do Pipefy expiram e, enquanto vivos, dão acesso à imagem do documento) — se precisar persistir o documento, subir pro Storage do Supabase com a mesma regra de acesso restrito a admin.
- Botões "+ Novo [registro]" ficam no topo do card, em destaque (não no fim da lista).
- Modais de criar/editar são compartilhados (mesmo formulário, título e texto do botão mudam, um campo oculto guarda o id em modo edição); salvar faz `PATCH` filtrando por id quando é edição, `POST` quando é criação.
- Sessão: front-end precisa refrescar o `access_token` do Supabase antes de expirar (1h) — ver bug corrigido abaixo. Qualquer novo fluxo de autenticação deve manter `ensureFreshSession()` antes de chamadas REST.

## Pendências conhecidas

- **Verificado em 20/10/2026:** o `index.html` do repo (commit `44c5364`) é idêntico ao publicado no GitHub Pages e contém Manutenções com fases de status de OS, franquia pool, edição de cadastros, telemetria e multas fase 1. A antiga pendência de "publicação manual não confirmada" está resolvida.
- Bug de sessão expirada ("Sem módulos liberados" ao reabrir aba após 1h+): correção (`ensureFreshSession()` dentro de `rest()`) **já está publicada** — falta só confirmar na prática, testando login após sessão longa (1h+ com a aba aberta).
- Financeiro e Recargas: falta edição/exclusão (hoje só criação).
- Carros Elétricos: falta a comparação de custo/impacto ambiental vs. combustão no front; atualizar o texto "Integração em teste" do card de telemetria.
- `frota.revisoes_preventivas` está vazia (colunas de preventiva existem na planilha-fonte, não foram importadas ainda).
- Multas: dashboard analítico (fase 2) não iniciado — aguardando pedido explícito. Falta popular `motorista_identificado_id` nas multas antigas antes de poder construir ranking/pontuação de CNH.
- Tabela de diagnóstico vazia `frota._ping_test` não pôde ser removida (DROP travando) — inofensiva, pode ser limpa manualmente no SQL Editor quando o problema de DROP for resolvido.
- Token `QUESTAR_API_TOKEN` foi compartilhado em texto puro no chat em algum momento — considerar rotacionar no portal da Questar.
- Integração Pipefy e Metabase: ainda não iniciada, aguardando credenciais.
- Usuários além de Jefferson (admin) e Vitor Hugo (operador: manutenção/multas/financeiro) — adicionar conforme necessário em `usuarios_perfil`.

## Como continuar

Este arquivo deve ser lido primeiro ao abrir uma sessão do Claude Code neste repositório. Ele reflete o estado verificado em 20/10/2026 (front-end conferido contra o `index.html` publicado, commit `44c5364`). O schema do Supabase (`efmpzjkqiwyuumaoumof`) não foi reconferido nessa verificação — confirme contra o banco real antes de assumir detalhes de tabelas/views, e confira o `index.html` atual se houver commits posteriores.
