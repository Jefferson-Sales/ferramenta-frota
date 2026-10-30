# Pendências e Backlog — Ferramenta da Frota

Atualizado em: 21/10/2026

Este arquivo reúne tudo que falta ajustar ou construir na ferramenta, organizado por módulo/tema. A ideia é usar como checklist: vá marcando `[x]` conforme o Claude Code for implementando, e peça item por item (ou por seção) em cada sessão, pra não misturar muita coisa de uma vez.

---

## 1. Pendências técnicas já identificadas

- [ ] Testar login após sessão longa (1h+) com aba aberta, pra confirmar na prática que a correção de "sessão expirada" funciona.
- [x] Importar dados de `revisoes_preventivas` da planilha-fonte. _(23/10/2026: 906 revisões da aba "Controle de Revisões" + 80 marcos "a conferir"; km atual de 325 carros atualizado pela planilha.)_
- [ ] Multas — fase 2 (dashboard analítico: ranking de infratores, pontuação CNH, custo mensal). Pré-requisito: popular `motorista_identificado_id` nas multas antigas.
- [ ] Remover a tabela de diagnóstico `_ping_test` (o DROP trava via MCP — fazer manual no SQL Editor do Supabase).
- [ ] Rotacionar o token `QUESTAR_API_TOKEN` (foi exposto em texto puro no chat em algum momento).
- [ ] Integração Pipefy e Metabase — aguardando credenciais (ver seção 2, pode ficar obsoleto se o agente de WhatsApp substituir o Pipefy para OS).
- [ ] Cadastrar outros usuários além de Jefferson e Vitor Hugo em `usuarios_perfil`, conforme necessário.
- [ ] Permitir edição e exclusão em Financeiro (Fornecedores, Notas Fiscais) e em Recargas — hoje só existe criação.
- [ ] Criar comparação de custo (elétrico vs. combustão) na tela de Carros Elétricos — a descrição do painel promete isso, mas ainda não existe no front-end.
- [ ] Atualizar o texto "Integração em teste" na tela de telemetria (a sincronização automática já roda em produção).
- [ ] **Dados pessoais de motoristas (projeto à parte, pedido em 23/10/2026):** cifrar CPF, RG, número da CNH e data de nascimento em `motoristas` e `motoristas_cadastros` (hoje texto comum, leitura só admin) e registrar cada leitura, no mesmo padrão da senha de abastecimento. Atenção: a checagem de CPF duplicado do auto-cadastro e a busca por CPF dependem do texto — planejar antes (ex.: guardar também um HMAC do CPF para comparar).
- [x] Ajustar cabeçalho fixo/correto nas demais tabelas do sistema (correção já aplicada em Veículos no Cadastro da Frota — estender o mesmo padrão às outras telas).

---

## 2. Abertura de chamados via WhatsApp/Slack (substituir o Pipefy)

- [ ] Criar um agente para WhatsApp (ou Slack) que permita abrir chamados (OS de manutenção) diretamente pelo app de mensagens, eliminando a dependência do Pipefy.

> **Observação para detalhar com o Claude Code:** esse é o item mais complexo da lista — vale conversar sobre a arquitetura antes (webhook do WhatsApp Business API ou Slack, autenticação de quem está abrindo o chamado, como os dados caem no Supabase). Sugiro tratar como projeto próprio, não como um ajuste pontual.

---

## 3. Módulo de Manutenções (OS)

- [x] Ao registrar um sinistro, incluir campo indicando se o carro **fica indisponível** ou **continua rodando**. _(entregue em 23/10/2026)_
- [x] Permitir cadastrar uma oficina nova diretamente na tela de abertura de OS (sem precisar sair do fluxo).
- [x] Incluir campo de busca por placa na abertura de OS.
- [x] Puxar o contato da oficina automaticamente (a partir do cadastro dela), ao selecioná-la na OS.
- [x] No cadastro de oficina, pedir: nome, telefone, endereço e CNPJ. _(21/10/2026: colunas `telefone`, `endereco`, `cnpj` criadas em `frota.oficinas`; telefone obrigatório no formulário, endereço e CNPJ opcionais; oficinas agora podem ser editadas clicando na linha.)_
- [x] Criar checklist para os auxiliares de frota, com campo para incluir fotos de avarias — permitindo gestão visual da frota dentro do próprio sistema. _(21/10/2026: fases 1 a 5 prontas — tabelas, catálogo, bucket `checklist-fotos`, formulário mobile `checklist.html`, módulo "Qualidade da Frota" no `index.html` (painel por status, anomalias abertas com Resolvida/Descartar, histórico por veículo com fotos) e e-mail automático de anomalia nova para frota@beepsaude.com.br, enviado pela conta do Jefferson.)_
- [x] Checklist: grupo "Equipamentos" (Celular, Cabo de carregador, Carregador, Suporte do celular) nos três tipos. _(22/10/2026)_
- [x] Checklist: trava de devolução pendente (motorista não retira outro carro sem devolver o anterior; fechamento pelo painel com motivo; data/hora de cada checklist e travas registradas). _(22/10/2026)_
- [x] Checklist: "Abrir OS" direto de uma anomalia (preenche a OS com placa/motivo e liga a anomalia à OS). _(22/10/2026: várias anomalias do mesmo carro por OS; ao concluir a OS o painel pergunta se cada uma foi resolvida; OS cancelada reabre as anomalias.)_
- [x] Dash de Gestão de Manutenção (disponibilidade, SLA, quebras, custo, checklist por dia, anomalias, revisões vencidas/vencendo e lista "a conferir" com Feita/Não feita; tudo filtrado por hub; Excel). _(23/10/2026)_
- [x] Revisões preventivas por km: plano de itens KWID (provisório, a confirmar com a caderneta Renault) dentro da OS de preventiva; OS concluída grava a revisão. _(23/10/2026)_
- [ ] Plano de revisão para os outros modelos (BYD, Yaris, motos, Strada) — hoje aparecem como "sem plano" e não alertam.
- [ ] Confirmar a lista de itens do KWID com a caderneta oficial Renault e tirar o aviso "a confirmar" (tabela `revisao_itens_plano`, coluna `provisorio`).
- [ ] Painel no celular: o menu lateral não se recolhe e o conteúdo fica espremido (vale para todos os módulos, não só o Dash).
- [ ] Checklist (cosmético, baixa prioridade): na mensagem "Faltam fotos obrigatórias" da Inspeção técnica, listar as fotos sempre na mesma ordem (painel, frontal, traseira) — hoje a ordem varia (`finalizar_checklist` usa `string_agg` sem `order by`).
- [x] Checklist: auto-cadastro de motorista sem cadastro (campos do pipe de Cadastro de Motoristas do Pipefy), com aprovação só por admin no painel e senha de abastecimento cifrada. _(22/10/2026)_
- [x] Checklist: limitar tentativas de matrícula por aparelho/IP na Edge Function `checklist`. _(22/10/2026: 5 erros em 15 min bloqueiam 15 min por aparelho e por IP; IP/aparelho guardados só cifrados.)_  Hoje a matrícula (4 dígitos) não tem limite de tentativas, então dá para chutar matrículas e enviar checklists falsos. A resposta só mostra primeiro e último nome, sem dado sensível. Não trava o lançamento, mas tratar em breve.

---

## 4. Controle de acesso por Hub

- [x] Criar grupos de acesso por Hub, filtrando as placas visíveis conforme o usuário logado. _(21/10/2026: vale só em Manutenções e Qualidade da Frota — e na busca de placa do auxiliar no `checklist.html`; admin vê tudo; hubs marcados por usuário na tela Gerenciar acessos; demais módulos sem filtro de hub.)_
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

## 7. Novos pedidos (29/10/2026)

- [ ] **Relatório Executivo RPS (PDF):** botão (ou rotina) que exporta um consolidado com os KPIs da reunião — Disponibilidade, OS, Financeiro e Elétricos — a partir dos mesmos números da Visão Executiva. Sem nome de motorista nem dado pessoal.
- [ ] **Botão SOS no checklist:** acionamento rápido para o motorista em rota avisar a Frota e o líder, mostrando o telefone de socorro/guincho da locadora do veículo. A conversar antes: para quem vai o aviso (e-mail? WhatsApp?), onde fica o telefone de socorro de cada locadora (cadastro do fornecedor) e se o aviso guarda localização (hoje a regra é **não** guardar localização).
- [ ] **Mural de Sugestões:** espaço na ferramenta para a equipe registrar melhorias (quem sugeriu, data, situação: nova / em análise / feita / descartada).

## 8. Pedidos de 30/10/2026

- [x] **Nova OS:** um campo só de placa (com sugestões ao digitar), sem o select duplicado. _(30/10/2026)_
- [x] **Menu:** "Qualidade da Frota" passa a se chamar **"Gestão de Checklist"**. _(30/10/2026)_
- [x] **Gerenciar acessos:** admin redefine a senha de login de um usuário (digitada ou gerada; cada troca registrada). _(30/10/2026)_
- [ ] **Painel Operacional do Auxiliar** (tela inicial focada na rotina do hub, cards clicáveis) — desenho em `docs/plano.md`, seção "Painel Operacional do Auxiliar".

---

## Como usar este arquivo com o Claude Code

1. Abra o Claude Code na pasta do repositório (`ferramenta-frota`).
2. Cole uma seção (ou um item) por vez — por exemplo, comece pela seção 3 (Manutenções) ou pela 5 (Multas), que têm itens mais objetivos e rápidos de implementar.
3. Depois de cada entrega testada e aprovada, marque o item como feito aqui e peça pro Claude Code commitar + dar push.
4. Deixe a seção 2 (agente de WhatsApp) para uma conversa à parte — vale planejar a arquitetura antes de pedir implementação direta.
