# Pendências e Backlog — Ferramenta da Frota

Atualizado em: 21/10/2026

Este arquivo reúne tudo que falta ajustar ou construir na ferramenta, organizado por módulo/tema. A ideia é usar como checklist: vá marcando `[x]` conforme o Claude Code for implementando, e peça item por item (ou por seção) em cada sessão, pra não misturar muita coisa de uma vez.

---

## 1. Pendências técnicas já identificadas

- [ ] Testar login após sessão longa (1h+) com aba aberta, pra confirmar na prática que a correção de "sessão expirada" funciona.
- [ ] Importar dados de `revisoes_preventivas` da planilha-fonte (hoje a tabela está vazia).
- [ ] Multas — fase 2 (dashboard analítico: ranking de infratores, pontuação CNH, custo mensal). Pré-requisito: popular `motorista_identificado_id` nas multas antigas.
- [ ] Remover a tabela de diagnóstico `_ping_test` (o DROP trava via MCP — fazer manual no SQL Editor do Supabase).
- [ ] Rotacionar o token `QUESTAR_API_TOKEN` (foi exposto em texto puro no chat em algum momento).
- [ ] Integração Pipefy e Metabase — aguardando credenciais (ver seção 2, pode ficar obsoleto se o agente de WhatsApp substituir o Pipefy para OS).
- [ ] Cadastrar outros usuários além de Jefferson e Vitor Hugo em `usuarios_perfil`, conforme necessário.
- [ ] Permitir edição e exclusão em Financeiro (Fornecedores, Notas Fiscais) e em Recargas — hoje só existe criação.
- [ ] Criar comparação de custo (elétrico vs. combustão) na tela de Carros Elétricos — a descrição do painel promete isso, mas ainda não existe no front-end.
- [ ] Atualizar o texto "Integração em teste" na tela de telemetria (a sincronização automática já roda em produção).
- [x] Ajustar cabeçalho fixo/correto nas demais tabelas do sistema (correção já aplicada em Veículos no Cadastro da Frota — estender o mesmo padrão às outras telas).

---

## 2. Abertura de chamados via WhatsApp/Slack (substituir o Pipefy)

- [ ] Criar um agente para WhatsApp (ou Slack) que permita abrir chamados (OS de manutenção) diretamente pelo app de mensagens, eliminando a dependência do Pipefy.

> **Observação para detalhar com o Claude Code:** esse é o item mais complexo da lista — vale conversar sobre a arquitetura antes (webhook do WhatsApp Business API ou Slack, autenticação de quem está abrindo o chamado, como os dados caem no Supabase). Sugiro tratar como projeto próprio, não como um ajuste pontual.

---

## 3. Módulo de Manutenções (OS)

- [ ] Ao registrar um sinistro, incluir campo indicando se o carro **fica indisponível** ou **continua rodando**.
- [x] Permitir cadastrar uma oficina nova diretamente na tela de abertura de OS (sem precisar sair do fluxo).
- [x] Incluir campo de busca por placa na abertura de OS.
- [x] Puxar o contato da oficina automaticamente (a partir do cadastro dela), ao selecioná-la na OS.
- [x] No cadastro de oficina, pedir: nome, telefone, endereço e CNPJ. _(21/10/2026: colunas `telefone`, `endereco`, `cnpj` criadas em `frota.oficinas`; telefone obrigatório no formulário, endereço e CNPJ opcionais; oficinas agora podem ser editadas clicando na linha.)_
- [x] Criar checklist para os auxiliares de frota, com campo para incluir fotos de avarias — permitindo gestão visual da frota dentro do próprio sistema. _(21/10/2026: fases 1 a 5 prontas — tabelas, catálogo, bucket `checklist-fotos`, formulário mobile `checklist.html`, módulo "Qualidade da Frota" no `index.html` (painel por status, anomalias abertas com Resolvida/Descartar, histórico por veículo com fotos) e e-mail automático de anomalia nova para frota@beepsaude.com.br, enviado pela conta do Jefferson.)_
- [ ] Checklist: "Abrir OS" direto de uma anomalia (preenche a OS com placa/motivo e liga a anomalia à OS) — adiado, sem mexer no fluxo de OS por enquanto.
- [ ] Checklist: limitar tentativas de matrícula por aparelho/IP na Edge Function `checklist`. Hoje a matrícula (4 dígitos) não tem limite de tentativas, então dá para chutar matrículas e enviar checklists falsos. A resposta só mostra primeiro e último nome, sem dado sensível. Não trava o lançamento, mas tratar em breve.

---

## 4. Controle de acesso por Hub

- [ ] Criar grupos de acesso por Hub, filtrando as placas visíveis conforme o usuário logado.
  - Exemplo: auxiliar de frota de Alphaville só vê os carros daquele hub.

---

## 5. Módulo de Multas

- [ ] Retirar o campo "número da notificação".
- [ ] Ao preencher o código de enquadramento, preencher automaticamente: grau da infração, pontos na CNH e motivo da multa.
- [ ] Retirar os campos "valor considerado" e "valor absorvido pela empresa".
- [ ] Incluir campo para marcar se o valor foi **cobrado do motorista** ou **absorvido pela empresa**.
- [ ] Incluir campo de busca por nome do motorista.
- [ ] Retirar a opção de indicar o supervisor do motorista.
- [ ] Unificar as datas: hoje existe "dia de abertura do pipe" e "dia de envio à liderança" como campos separados — deixar apenas a data de abertura do pipe (o envio à liderança acontece no mesmo dia).
- [ ] Criar duas fases — **⚠️ a detalhar com o Jefferson**: não ficou claro quais são as duas fases (do fluxo de multas? status da notificação/recurso? etapas de aprovação?).

---

## 6. Carros Elétricos

- [ ] Trazer o percentual de bateria dos carros elétricos na ferramenta, puxando da telemetria (já integrada via API Questar/Exodus).

---

## Como usar este arquivo com o Claude Code

1. Abra o Claude Code na pasta do repositório (`ferramenta-frota`).
2. Cole uma seção (ou um item) por vez — por exemplo, comece pela seção 3 (Manutenções) ou pela 5 (Multas), que têm itens mais objetivos e rápidos de implementar.
3. Depois de cada entrega testada e aprovada, marque o item como feito aqui e peça pro Claude Code commitar + dar push.
4. Deixe a seção 2 (agente de WhatsApp) para uma conversa à parte — vale planejar a arquitetura antes de pedir implementação direta.
