# Plano — Padronização visual + Visão Executiva (Diretoria)

Criado em 23/10/2026. **Aprovado pelo Jefferson em 23/10/2026.**

## Retomar daqui (29/10/2026)

**Etapa 1 da esteira de descontos: no banco e testada** (aprovada pelo Jefferson em 29/10/2026). Criados `ctb_infracoes` (16 linhas a conferir), `multas.ctb_codigo`, `parcelas_sugeridas`, `descontos_folha` (fases e caminhos no gatilho), `descontos_historico` (imutável) e o bucket `descontos-anexos`. Testes de banco: 138 ok (34 novos). Nada aparece na tela ainda. Migration `sql/2026-10-29-e1-descontos-folha.sql`.

**Próximos passos:**
1. **Jefferson:** conferir a lista do CTB (códigos `PROV-nn`, gravidade e valor) — ou mandar a exportação do Pipefy para carregar a lista completa (vem junto com a E5). Enquanto nenhuma linha estiver conferida, a gravidade não é preenchida sozinha e o rodízio não vira Custo Beep automático.
2. **E3** sugestão de motorista — **feita em 29/10/2026** (função + gatilho + 16 testes).
   **E4a** (lista e detalhe dos descontos) — **feita em 29/10/2026**. **E4b** (abrir desconto pela multa e pela OS, CTB, sugestão de motorista, valor bruto/com desconto) — **feita em 30/10/2026** (157 testes de banco e 157 da tela; conferida no navegador com dados fictícios, computador e celular). **E4c** (botões da esteira + Corrigir dados com justificativa) — **feita em 30/10/2026** (194 testes da tela; banco: seções de descontos 33/33, 7 casos novos na seção 19; conferida no navegador, computador e celular). Próxima: **E4d** (anexos).
3. **E4** tela da esteira em Multas (com anexos no bucket).
4. **E5** importação dos 291 cards; **E6** Visão Executiva (Repasse × Custo Beep).

Também em 29/10/2026: rotina das 02:00 de 28/10 e 29/10 conferida (0 divergência, hodômetro por dia, dia de Brasília) e `km_atual` do TUP4J22 corrigido de 0 para 660,4 (última leitura da Questar, 17/09; aprovado pelo Jefferson).

## Retomada anterior (fim do dia 27/10/2026 — concluída)

Feito em 27/10/2026 (tudo publicado; push até `08a41fa`, depois só commits do plano): Multas C3 na Visão Executiva, cards clicáveis do Dash, Excel analítico do checklist, backfill da Questar (D4b, 13.621 viagens), correção da sincronização diária (D4c) com reprocessamento de 12/10–27/10, as 3 levas dos elétricos e o mapeamento/decisões da esteira de Multas e Avarias.

## Retomada anterior (fim do dia 23/10/2026 — concluída)


Já no ar (push `deb4123`): Visão Executiva com Operação (C1), Carros Elétricos (C2) e Financeiro (C4).

Definições registradas hoje (detalhes nas seções abaixo):
1. **Financeiro (C4) — fechamento dinâmico:** mês fecha no dia 05 do mês seguinte (passa a contar na média), mas nunca é congelado: nota lançada depois com aquela competência soma na hora no realizado, na média dos 3 meses e na projeção do ano.
2. **Carros Elétricos — backfill da Questar:** script de carga retroativa das viagens/km desde **01/02/2026** até 12/10/2026 (etapa **D4b**).
3. ~~Próximo passo: terminar e publicar o quadrante de Multas (C3)~~ — feito em 27/10/2026 (ver Andamento).

**Multas (C3) — em andamento, ainda NÃO commitado** (as mudanças estão só no computador do Jefferson, na pasta do projeto):
- Pronto: função `frota.exec_multas(p_ini, p_fim, p_hub)` **já aplicada no banco** (não é usada pela tela ainda, então não muda nada para ninguém) — totais do período por status, hub e motivo; fila atual "aguardando retorno da liderança" (192 hoje); última infração registrada (26/09/2026). O nome do motorista que aparece no começo de 11 descrições ("Motorista (planilha): …") nunca vira motivo. Arquivo `sql/2026-10-23-c3-exec-multas.sql`.
- Pronto e testado: `Regras.motivoDaDescricao` e `Regras.classificarMotivo` (agrupa os 44 textos de motivo em ~16 categorias: velocidade até 20% / 20–50% / acima de 50%, sinal vermelho, estacionamento, faixa exclusiva, marcha à ré, contramão etc.) — 116 testes da tela passando.
- Pela metade: filtros na tela de Multas (hub, status, motivo, mês da infração; a lista passa a carregar todas as 459 em vez de 300) — código escrito em `index.html`, ainda **não conferido na tela**.
- Falta: o quadrante na Visão Executiva (multas e valor no período, fila da liderança, ranking por hub, principais motivos, ranking de motoristas "Sem dados" até D2), o clique levando à tela de Multas filtrada (`exIr`), testes de banco do `exec_multas`, conferir no navegador, atualizar CLAUDE.md e push.
- Dados de hoje que a tela precisa explicar: as notificações chegam com atraso (nenhuma infração registrada em outubro ainda); grau, pontos, código e motorista vazios nas 459 multas; o alerta "liderança sem retorno" fica zerado porque a data de envio à liderança nunca é preenchida.

## Próximo passo — Multas e Avarias: esteira operacional (anotado em 27/10/2026)

Publicado em 27/10/2026 (push `dc8cc52`): quadrante de Multas (C3, Visão Executiva completa), cards clicáveis do Dash de Manutenção e Excel analítico do checklist de retirada.

O Jefferson está levantando no Claude Desktop o **mapeamento detalhado das fases e campos dos pipes de Multas e de Avarias do Pipefy**. Com esse mapeamento em mãos, o próximo passo é alinhar a esteira operacional na ferramenta:
- **Status:** as fases do Pipefy viram os status da multa/avaria (hoje `multas.status` tem recebida_email, enviada_lideranca, aguardando_retorno_lideranca, infrator_identificado, infrator_nao_identificado, enviada_locadora etc. — conferir um a um contra o mapeamento).
- **Indicação de infrator:** ligar a multa ao motorista do cadastro (`motorista_identificado_id`; é também a etapa D2, que destrava o ranking de motoristas).
- **Envio para o DP** (desconto em folha): registrar quando e por quem foi enviado.
- **Divisão do valor: Repasse Motorista × Custo Beep** (hoje existem `valor_absorvido_empresa` e `paga_por`, vazios nas 459 multas).
- **Avarias:** ainda não existe na ferramenta — desenhar a partir do mapeamento (provável ligação com as anomalias do checklist e com as OS de sinistro).
- Não começar antes de receber o mapeamento. Dados pessoais (CPF, CNH) seguem só admin.

### Mapeamento do Pipefy recebido (27/10/2026, levantamento do Jefferson no Claude Desktop)

**Não são dois pipes:** Multas e Avarias rodam num único pipe, **"[Frota] Descontos em folha de colaborador"** (291 cards). O campo **"Ocorrência para desconto"** diz o tipo: **Multa** ou **Manutenção** (= avaria/dano). Na ferramenta, o desenho natural é **uma esteira só de "descontos"** com tipo multa/avaria, reaproveitando `multas` para as multas e ligando avarias às OS — decidir no desenho técnico.

**Fases (viram os status):**
1. **Enviado ao líder** — o motorista concorda? *Sim* / *Não* (contestou) / *Motorista já desligado*.
2. **Avaliação do Time de Frota** — só se houve contestação; a contestação é válida? *Sim* / *Não*.
3. **Conferência Frota** — *Sim, enviar ao DP* / *Devolver ao líder* / *Não cobrar (Custo Beep)*.
4. **Encaminhado para o DP** — validação documental do desconto.
5. **Finais:** *Confirmado pelo DP* (cobrança do motorista), *Custo Beep*, *Rejeitadas*, *Cobrança errada*.

**Regras de negócio:**
- **Divisão financeira:** *Confirmado pelo DP* = **Repasse Motorista**; *Custo Beep* = **absorvido pela empresa**; *Rejeitadas* e *Cobrança errada* **não contam como custo** (nem para a Beep nem para o motorista). Vai para `paga_por`/`valor_absorvido_empresa` (hoje vazios) e para o quadrante de Multas da Visão Executiva.
- **Rodízio municipal:** na lista de motivos do CTB, "RODÍZIO MUNICIPAL" já nasce como **Custo Beep** (não vai ao líder nem ao DP).
- **Avarias (Manutenção):** vincular direto à **OS** para puxar orçamento/custo e as fotos da anomalia do checklist (anomalia → OS já existe desde 22/10/2026).
- **Auto-preenchimento:** ao informar **Placa + Data/Hora + Código CTB**, a ferramenta busca quem era o motorista, o hub e o líder naquele momento e preenche pontuação, gravidade e sugestão de parcelamento.

**Decisões do Jefferson (27/10/2026):**
- **Quem estava com o carro:** a ferramenta **sugere** pelo checklist de Retirada (matrícula + hora) ou pela telemetria (`driver_code` da Questar, só elétricos; falta ligar código → matrícula). Sem registro (ou multa anterior a essas fontes), o operador **busca e seleciona o motorista à mão** (lista de `v_motoristas_basico`, sem dados sensíveis).
- **Líder:** campo de seleção/texto no formulário inicial, **opcional** — não trava o fluxo.
- **Pontuação e gravidade:** criar uma **tabela de referência do CTB** com as infrações mais comuns (código → descrição, gravidade, pontos, valor). Pontos por gravidade = Leve 3, Média 4, Grave 5, Gravíssima 7 (já é `Regras.PONTOS_POR_GRAU`). "Rodízio municipal" marcado como Custo Beep direto.
- **Sugestão de parcelamento (regra do Pipefy):** Leve **1x**, Média **até 3x**, Grave/Gravíssima **até 6x**; o operador pode ajustar. Vai para `regras.js` com teste.
- **Histórico:** **importar os 291 cards** do Pipefy depois que as tabelas estiverem prontas, para manter a série de 2026 completa (com a fase atual de cada card).
- **Motorista já desligado** (decisão de 27/10/2026): o DP não consegue descontar em folha regular → vai para a fila **"Análise RH / Custo Beep"**. Se houver retenção rescisória, segue para o DP; se não houver, baixa direto como **Custo Beep** com o motivo **"Motorista desligado"**.
- **Devolver ao líder** (decisão de 27/10/2026): volta para a fase 1 ("Enviado ao líder") e exige **"Observações da Frota"** com o motivo (documento ilegível, falta de anexo, termo sem assinatura…).

### Proposta do banco — esteira de descontos (27/10/2026, aguardando aprovação)

Ideia central: **`multas` continua sendo a multa** (recebimento e identificação do condutor junto à locadora); a **cobrança** (o pipe "Descontos em folha") vira uma tabela nova, que serve para multa **e** avaria.

1. **`ctb_infracoes`** (referência): código de enquadramento + desdobramento, descrição, gravidade (`grau_infracao`), pontos (pela gravidade), valor, `custo_beep_padrao` (rodízio municipal = sim), ativo. Leitura para quem vê Multas; escrita só admin. Carga inicial: infrações mais comuns, **conferidas pelo Jefferson** antes de valer (códigos e valores não entram "de memória").
2. **`descontos`** (a esteira): tipo `multa`/`avaria`; `multa_id` (multa) ou `os_id` + `anomalia_id` (avaria, puxa orçamento/custo e fotos); veículo, hub, data/hora da ocorrência; motorista (`motorista_id`) + **sugestão** (`motorista_sugerido_id`, `origem_sugestao` checklist/telemetria/manual); líder (texto opcional); valor, parcelas sugeridas e parcelas escolhidas; **fase**; respostas de cada fase (motorista concorda: sim/não/desligado; contestação válida; decisão da conferência; retenção rescisória); `observacoes_frota`; `motivo_custo_beep`; `pipefy_card_id` (importação, único).
   - **Fases:** `enviado_lider` → `avaliacao_frota` (só com contestação) → `conferencia_frota` → `encaminhado_dp` → finais `confirmado_dp`, `custo_beep`, `rejeitada`, `cobranca_errada`; mais `analise_rh` (desligado).
   - **Resultado financeiro** (calculado, não digitado): `confirmado_dp` = Repasse Motorista; `custo_beep` = absorvido pela Beep; `rejeitada`/`cobranca_errada` = sem custo.
   - As trocas de fase passam por uma função que só aceita os caminhos da árvore e exige os campos de cada passo (ex.: devolver ao líder sem observação é recusado). A mesma regra fica em `regras.js`, com teste dos dois lados.
3. **`descontos_historico`**: cada troca de fase (de → para, quem, quando, observação). Imutável, como o histórico da OS.
4. **Anexos** (termo assinado, documentos): bucket privado `descontos-anexos`, acesso só de quem opera Multas e de admin (o termo tem nome e assinatura do colaborador).
5. **`sugerir_motorista(placa, data_hora)`**: procura a Retirada aberta naquele momento (checklist) e, nos elétricos, o `driver_code` da viagem (falta ligar o código à matrícula). Devolve só id + nome; sem resultado, o operador escolhe à mão.
6. **Parcelamento sugerido (sempre ajustável, teto de 6x):** `Regras.parcelasSugeridas`.
   - **Multa, pela gravidade:** Leve 1x, Média até 3x, Grave/Gravíssima até 6x.
   - **Avaria, pelo valor** (decisão do Jefferson, 27/10/2026): até R$ 300,00 → 1x; acima de R$ 300,00 até R$ 600,00 → até 3x; acima de R$ 600,00 → até 6x. (Centavos entre 300 e 301 contam como a faixa de 3x.)
7. **Acesso:** mesmo módulo de Multas (ver = `posso_ver('multas')`, mexer = quem opera Multas). Multas não tem filtro de hub hoje.
8. Visão Executiva: Repasse Motorista × Custo Beep por mês e por hub, sem nomes.

**Etapas sugeridas:** E1 tabela CTB + parcelamento (com testes) → E2 `descontos` + fases + histórico (com testes) → E3 sugestão de motorista → E4 tela → E5 importação dos 291 cards → E6 Visão Executiva.

### Etapa 1 — desenho detalhado (29/10/2026, **aprovado e aplicado no banco em 29/10/2026**)

**Decisões do Jefferson (29/10/2026) que fecharam o desenho:**
- **Contestação válida:** se a empresa absorve → Custo Beep (com motivo); se provou que o infrator era outro colaborador → a Frota troca o motorista e o card volta para "Enviado ao líder" (o banco exige a troca e a observação).
- **Rejeitada (pelo DP):** falha documental (termo ilegível, CNH ausente, perda de prazo de folha) — **não é final**: volta para a Frota corrigir e reenviar ao DP (exige dizer o que foi corrigido). Rejeitada → Custo Beep (com motivo) **confirmado pelo Jefferson em 29/10/2026**: quando o DP não consegue executar o desconto e a Beep absorve.
- **Cobrança errada (pela Frota):** cancelamento definitivo (multa duplicada, cobrança indevida da locadora, erro no AIT), de qualquer fase em andamento, com motivo; final sem custo.
- **CTB:** carga inicial com os enquadramentos mais frequentes, todos com `conferido = false`; a lista completa vem com a importação dos 291 cards.

**Já feito:** `Regras.parcelasSugeridas(tipo, grau, valor)` + `Regras.parcelasValidas(n)` (1 a 6) em `regras.js`, com 23 testes (139 no total). A mesma regra vai para o banco (`frota.parcelas_sugeridas`) com teste em `regras.test.sql`.

**`frota.ctb_infracoes`** (referência): `codigo` (texto, chave — enquadramento + desdobramento, ex. "745-50"), `descricao`, `grau` (`grau_infracao`), `pontos` (calculado pela gravidade: 3/4/5/7), `valor`, `custo_beep_automatico` (rodízio = sim), `conferido` (só vale para sugestão depois que o Jefferson conferir), `ativo`. RLS: lê quem vê Multas; grava só admin. `multas` ganha `ctb_codigo` (opcional) — as 459 antigas continuam como estão.

**`frota.descontos_folha`** (a esteira):
- tipo `multa`/`avaria`; `multa_id` (único — uma cobrança por multa) ou `os_id` + `anomalia_id` (avaria; OS opcional para não travar a importação do Pipefy);
- `veiculo_id`, `hub_id` (**hub no momento da ocorrência**, guardado — para o custo por hub não mudar se o carro trocar de hub), `ocorrida_em`, `ctb_codigo`, `grau`;
- `motorista_id`, `motorista_sugerido_id`, `origem_sugestao` (checklist/telemetria/manual/importacao), `lider_nome` (opcional);
- `valor` (> 0), `parcelas_sugeridas`, `parcelas` (1–6);
- `fase` + respostas: `motorista_concorda` (sim/nao/desligado), `contestacao_motivo`, `contestacao_valida`, `retencao_rescisoria`, `observacoes_frota`, `motivo_custo_beep`, `motivo_dp`;
- `resultado` calculado pela fase: Repasse Motorista / Custo Beep / Sem custo / (em andamento);
- `pipefy_card_id` (único), quem criou, datas.

**Caminhos permitidos** (gatilho no banco recusa qualquer outro e confere os campos de cada passo):

| De | Para | Exige |
|---|---|---|
| (criação) | Enviado ao líder | — ; se o CTB for Custo Beep automático (rodízio) → nasce em **Custo Beep**, motivo "Rodízio municipal" |
| Enviado ao líder | Conferência Frota | motorista concorda = sim |
| Enviado ao líder | Avaliação da Frota | concorda = não + motivo da contestação |
| Enviado ao líder | Análise RH / Custo Beep | concorda = motorista desligado |
| Avaliação da Frota | Conferência Frota | contestação **não** válida |
| Avaliação da Frota | Custo Beep | contestação válida + motivo |
| Avaliação da Frota | Enviado ao líder | contestação válida + **motorista trocado** + observação |
| Conferência Frota | Encaminhado ao DP | — |
| Conferência Frota | Enviado ao líder | Observações da Frota (≥ 5 letras) |
| Conferência Frota | Custo Beep | motivo do Custo Beep |
| Análise RH | Encaminhado ao DP | com retenção rescisória |
| Análise RH | Custo Beep | sem retenção → motivo "Motorista desligado" automático |
| Encaminhado ao DP | Confirmado pelo DP | — |
| Encaminhado ao DP | Rejeitada pelo DP (não final) | motivo |
| Rejeitada pelo DP | Encaminhado ao DP | o que foi corrigido |
| Rejeitada pelo DP | Custo Beep | motivo (DP não consegue descontar; Beep absorve) |
| qualquer fase em andamento | Cobrança errada | motivo |

Fases finais não mudam mais (só admin reabre, com motivo — fica no histórico).

**`frota.descontos_historico`**: cada troca de fase (de → para, observação, quem, quando), gravada por gatilho; **imutável** (mesmo padrão do histórico da OS).

**Acesso:** igual a Multas — vê quem tem `posso_ver('multas')`; cria/move quem opera Multas e admin; ninguém apaga (usa Rejeitada/Cobrança errada). Sem filtro de hub (Multas não tem).

**Fica para as próximas etapas:** tabela de anexos e envio pela tela (o bucket privado `descontos-anexos` já existe), sugestão de motorista (E3), tela (E4), importação do Pipefy (E5), Visão Executiva (E6).

### Decisões do Jefferson (29/10/2026, depois da Etapa 1)

- **CTB:** ficam os 16 enquadramentos com códigos `PROV-nn`; a lista completa é carregada e conferida na importação dos 291 cards (E5).
- **Rejeitada pelo DP → Custo Beep:** confirmado.
- **Ordem:** Etapa 3 (sugestão de motorista) e depois Etapa 4 (tela).

**Calibração da tela (Etapa 4):**
- Não mostrar os campos antigos "Valor considerado" e "Valor absorvido pela empresa". **Correção (29/10/2026):** "Valor considerado" é a coluna principal `multas.valor` (a que soma na Visão Executiva) — ela fica; o que sai é o campo separado na tela (ver pergunta na Etapa 4). "Valor absorvido pela empresa" (`valor_absorvido_empresa`) e "Paga por" (`paga_por`) somem da tela; as colunas ficam no banco (nada se apaga sem perguntar). O destino do valor sai da fase.
- Abertura simples: a data de cadastro é a data de envio ao líder (Fase 1) — o banco já faz isso (`criado_em` = início da fase "Enviado ao líder").
- Líder/supervisor totalmente opcional.
- Ao escolher a infração do CTB: preencher a descrição oficial, a gravidade e os pontos na CNH.
- Destino contábil claro na tela: **Confirmado pelo DP = Cobrança do motorista** × **Custo Beep = Empresa** (Cobrança errada = sem custo).

### Etapa 3 — sugestão de motorista (**aprovada e aplicada no banco em 29/10/2026**)

**Feito:** `frota.sugerir_motorista(veiculo, data_hora, usar_telemetria = false)` (só admin ou quem opera Multas; devolve id, nome, matrícula, origem, confiança, horários e um texto — sem CPF/CNH) e o gatilho `descontos_folha_sugestao`, que na criação preenche só `motorista_sugerido_id` quando há um único motorista apontado. `motoristas.questar_driver_code` (vazio) liga o código da Questar ao motorista quando houver identificação nos carros (o Jefferson confirmou em 29/10/2026 que hoje não há crachá/RFID). Fonte viva = checklist de Retirada; multas antigas e os 291 cards = Pipefy (E5) ou escolha manual. 16 testes de banco. Migration `sql/2026-10-29-e3-sugerir-motorista.sql`.

**Proposta original:**

**O que os dados mostram hoje (29/10/2026):**
- **Telemetria Questar:** o código do motorista (`driver_code`) está **vazio nas 19.280 viagens**. A Questar não sabe quem dirigia — a identificação de motorista (cartão/chaveiro ou app) não está ativa nos carros. Sem isso, a telemetria não sugere ninguém.
- **Checklist de Retirada:** só 4 Retiradas enviadas desde 21/10 (quase todas de teste). A regra funciona, mas só vai sugerir alguém quando os hubs usarem o checklist no dia a dia.
- **Multas existentes:** a última infração é de 26/09/2026, antes do checklist. Para elas, a sugestão não tem fonte; o motorista vem do card do Pipefy na importação (E5) ou é escolhido à mão.

**Proposta:**
1. Função `frota.sugerir_motorista(veiculo, data_hora)` que devolve **só** id, nome, de onde veio e o grau de confiança (nada de CPF/CNH). Quem pode chamar: admin ou quem opera Multas.
   - **Checklist:** a Retirada daquele carro enviada antes do horário e ainda aberta naquele horário (fechada depois ou sem devolução). Confiança **alta** se a devolução veio depois no mesmo turno; **média** se a Retirada estava aberta havia mais de 24 h (devolução atrasada); nenhuma sugestão se a matrícula não for de motorista do cadastro (ex.: auxiliar).
   - **Telemetria:** a viagem que cobre o horário, pelo `driver_code` ligado à matrícula. Fica pronta mas **desligada** até a Questar mandar o código (precisa de uma tabela de ligação código → motorista).
   - Se as duas fontes discordarem: mostra as duas e não escolhe sozinha.
2. Na criação do desconto, o banco preenche `motorista_sugerido_id` + `origem_sugestao`; o **motorista confirmado continua vazio até alguém confirmar** na tela (sugestão nunca vira cobrança sozinha).
3. Testes de banco com dados fictícios: Retirada cobrindo o horário, Retirada já devolvida, devolução atrasada, duas Retiradas no dia, matrícula de auxiliar, operador sem Multas recusado, nenhum dado pessoal no retorno.

### Etapa 4 — tela da esteira de descontos (aprovada em 29/10/2026)

**Decisões do Jefferson (29/10/2026):** formato **lista com contadores por fase** (não quadro tipo Pipefy); valor da multa = **Valor bruto** + **Valor com desconto (opcional)**, e o valor considerado (`multas.valor`) passa a ser calculado: com desconto se houver, senão o bruto (entra na E4b).

**Andamento:** E4a feita em 29/10/2026 (lista + detalhe + linha do tempo; regras `DESCONTO_FASES`/`faseDesconto`/`destinoContabil` com 10 testes; conferida no navegador com dados fictícios, computador e celular). Junto, corrigido um erro antigo: clicar nas abas da tela Motoristas deixava a Qualidade da Frota em branco (as abas da Qualidade respondiam a qualquer botão com a classe `qf-aba`).

**Onde:** dentro de Multas, uma aba nova **"Descontos em folha"** ao lado de "Multas registradas" (mesmo acesso de Multas). Avarias entram na mesma aba (tipo Avaria).

**Partes (uma por vez, cada uma conferida no navegador antes da próxima):**
- **E4a — lista e detalhe (só leitura):** contadores por fase no topo (clicáveis = filtro), filtros de tipo/hub/fase/mês, lista com placa, tipo, motivo, valor, parcelas, fase, há quanto tempo na fase e o **destino do valor** em etiqueta: *Cobrança do motorista* (Confirmado pelo DP), *Custo Beep (empresa)*, *Sem custo* (Cobrança errada), *Em andamento*. Detalhe com a linha do tempo do histórico.
- **E4b — abrir desconto:** botão "Enviar para desconto" na multa e "Cobrar avaria" no detalhe da OS, além do "+ Novo desconto". Formulário curto: placa + data/hora + infração do CTB (busca por código ou texto; ao escolher, preenche descrição oficial, gravidade e pontos), valor, parcelas (já com a sugestão, ajustável 1–6), líder opcional, e o cartão de **motorista sugerido** ("Sugerido: Nome — Retirada 08:15, devolvida 18:02 · confiança alta" com **Usar este** / **Escolher outro**; a lista vem de `v_motoristas_basico`). A data de cadastro é a data de envio ao líder.
- **E4c — andar na esteira:** no detalhe, só os botões permitidos na fase atual (os mesmos caminhos do banco), cada um pedindo o campo obrigatório daquele passo (motivo da contestação, Observações da Frota, motivo do Custo Beep, motivo da rejeição do DP, o que foi corrigido…). O banco continua sendo a trava final. **Feita em 30/10/2026**, com as decisões do Jefferson: a Frota registra as respostas do líder e do DP (histórico guarda quem registrou); botão **Corrigir dados** (motorista, valor, parcelas, líder) nas fases em andamento, cada alteração na linha do tempo com justificativa obrigatória (no banco também).
- **E4d — anexos:** enviar e ver termo assinado/documentos (PDF ou foto, até 10 MB) no bucket `descontos-anexos`, com link que vale 5 minutos.
- **Regras na tela:** `Regras.DESCONTO_FASES` (nomes), `Regras.destinoContabil(fase)` e `Regras.proximosPassos(fase)`, com teste.
- **Formulário de Multas:** sai "Valor absorvido pela empresa" e "Paga por"; entra a infração do CTB (preenche código, gravidade, pontos e motivo).

**Perguntas ao Jefferson antes de começar:**
1. **Valor da multa:** hoje o formulário tem "Valor bruto", "Valor com desconto" e "Valor considerado" (o que soma nos totais). Proposta: deixar só **Valor bruto** e **Valor com desconto (opcional)**, e o valor considerado passa a ser automático (com desconto se houver, senão o bruto). Ou prefere um campo único "Valor da multa"?
2. **Formato da lista:** lista com contadores por fase (funciona bem no celular) ou quadro em colunas tipo Pipefy (melhor no computador, ruim no celular)?

## Painel Operacional do Auxiliar (backlog, pedido do Jefferson em 30/10/2026)

Tela inicial de quem trabalha no hub (auxiliar de frota / operador de Manutenções e Checklist), focada na rotina do dia. Cards clicáveis, cada um levando à lista de pendentes e ao atalho de ação. Sempre só os hubs da pessoa (`hub_liberado`), sem dado pessoal sensível.

| Card | O que mostra | Clique leva a | Dados que já existem |
|---|---|---|---|
| **Checklists do dia** | Realizados × Não realizados (Retirada) | Lista de carros pendentes no dia | `checklist_visao_diaria(dia)` (mesma regra da Visão diária e do Dash) |
| **Fila de Preventivas** | Vencidas e a vencer | Atalho para **agendar OS** de preventiva (formulário de OS já com placa e marco) | `v_revisoes_status` |
| **Fila unificada de Avarias/Anomalias** | Anomalias abertas apontadas por motoristas ou auxiliares | Atalho **Abrir OS**, perguntando se o carro **roda ou parou** (`veiculo_parado`) | `v_anomalias_abertas` + "Abrir OS" da anomalia (já existe) |
| **Prazos de retorno vencidos** | OS em oficina com previsão de retorno já passada | Detalhe da OS (tratativas) | `ordens_servico.previsao_retorno` |
| **Contratos vencendo & km excedente** | Contratos a vencer e pool com km acima da franquia | Cadastro da Frota filtrado | `v_cadastro_frota` / `v_pool_km_contrato` (contratos não têm hub: definir se o auxiliar vê todos ou só os carros do hub) |

**Decisões do Jefferson (30/10/2026):**
- **Tela inicial padrão** de quem tem perfil operacional de hub (auxiliares/operadores). Admin acessa pelo menu lateral normalmente.
- Para o perfil operacional, **substitui a Visão Executiva**, que segue restrita à Diretoria/Gestão.
- **Filtro de hub estrito:** o auxiliar vê só veículos, contratos, anomalias e checklists do próprio hub. Contrato não tem hub no banco: "contrato do hub" = contrato com pelo menos um carro ativo naquele hub (a franquia em pool continua sendo do contrato inteiro — o card mostra o excedente do contrato e quantos carros dele estão no hub). Reaproveita as peças da Visão Executiva (`css/painel-exec.css` + `js/painel-exec.js`) e as RPCs que já existem; provavelmente uma RPC nova `painel_auxiliar(p_hub)` (security invoker) para juntar as contagens.

## Carros elétricos — as 3 levas da EvoMob (informado pelo Jefferson em 27/10/2026)

Usar esta evolução para calibrar qualquer cálculo histórico de frota, disponibilidade, custo e km por hub dos elétricos (não supor 60 carros desde o início do ano):

| Leva | Período | Carros | Praça | Nota de locação EvoMob |
|---|---|---|---|---|
| 1 | fev/mar a jun/2026 | 10 | SP | R$ 13.945 (fev, parcial) → R$ 27.890/mês |
| 2 | jul–ago/2026 (entrada gradual) | +25 | RJ | R$ 63.931 (jul) → R$ 110.918 (ago) |
| 3 | set/2026 | +25 | SP | R$ 173.052 (nota cheia, 60 carros) |

Total: **35 em SP** (cadastro: Barra Funda 28, Guarulhos 4, Alphaville 3) e **25 no RJ** (Barra da Tijuca 10, Niterói 8, São Cristóvão 7) — confere com o cadastro em 27/10/2026.

Conferência com a telemetria Questar (backfill D4b): mai–jun só Barra Funda (**6 dos 10 carros da leva 1** com viagem; nada antes de 14/05 — os 4 restantes e os meses fev–abr não têm telemetria); RJ aparece em jul (3 carros, poucos km) e ago (13), completo em set (25); SP em set: 32 carros com viagem. Atenção: o hub de cada viagem é o **hub atual** do carro (se um carro mudou de praça, o histórico vai junto). Para custo por km histórico, considerar só os carros/meses com telemetria (a nota da leva 1 em fev–abr não tem km correspondente).

## Decisões do Jefferson (23/10/2026)

- **Cores (Brandbook Beep):** Verde Beep `#00AFAA`; neutras/escuras `#F4F4F4`, `#E5E5E5`, `#1F5E89`; ciano/verde `#03E8DC`, `#04D4CE`, `#008E87`; laranjas `#FBA600`, `#F68300`, `#F36508`.
- **Cards/caixas:** cantos de 15–20px. **Botões:** sem degradê e sem canto reto.
- **Visão Executiva** abre primeiro só para Diretoria e Admin.
- **Orçado e planejado:** entram por importação de planilha (sem tela de digitação).
- **Uso diário da frota (realizado) — por telemetria, dividida por tipo de carro (correção do Jefferson, 23/10/2026):**
  - **Elétricos:** utilização, saídas e % de bateria pela API **Questar/Exodus** (D4) — só os elétricos têm Questar.
  - **Combustão** (quase toda a frota): utilização por **outra API de telemetria, fornecedor a definir** (D6) — o Jefferson envia na fase D.
  - O checklist de Retirada **não** é usado para medir uso.
- **Planejado da Utilização:** consulta do Metabase com agendas/rotas por dia (D5).
- **Manutenção (C1):** aprovados o histórico de status da OS e a tratativa com a oficina como histórico imutável.
- **Telemetria (D4):** aprovado testar o campo de nível para a bateria; **não** gravar latitude/longitude.
- **Prioridade:** A6 e B1 antes; A3 e A4 ficam para o fim.
- **Diretoria:** papel **Visualizador** + permissão "Visão Executiva" — só consulta, sem editar e sem dados pessoais sensíveis (que continuam só para admin).
- **Painel de Multas (fase 2):** liberado por este pedido.
- **Título do sistema:** "Gestão da Frota Beep Saúde", com logo da Beep ou ícone de carro ao lado (23/10/2026). Hoje usa um ícone de carro desenhado no código; trocar pelo logo oficial quando o Jefferson mandar o arquivo (SVG de preferência).
- **Visual da A6 aprovado** (23/10/2026).

## Andamento

- [x] **A1** `css/tokens.css` com as cores da Beep, carregado pelos dois HTML (23/10/2026). Também antecipado da A3: cores, cantos de 16px nos cards, 10px nos botões, sombras mais suaves.
- [x] **A2** Tabelas sem vazamento (23/10/2026).
- [x] **A5** Menu no celular + `<meta viewport>` que faltava no `index.html` (23/10/2026). Falta testar num celular real depois do push.
- [x] **Título** "Gestão da Frota Beep Saúde" + ícone de carro no login, menu e barra do celular (23/10/2026).
- [x] **A6** Peças da Visão Executiva (23/10/2026, aprovada pelo Jefferson): `css/painel-exec.css` + `js/painel-exec.js` (cartão de indicador clicável, "Sem dados", número principal com medidor, barras com meta/orçado, ranking, legenda, dica ao passar o mouse); demonstração com dados fictícios em `testes/painel-exec.demo.html`. Cores de gráfico `--grafico-1/2` validadas para daltonismo e contraste.
- [x] **B1** Permissão "Visão Executiva" (módulo `executivo`, só Visualizador; Admin vê) e tela base com filtros de período e hub; primeiro item do menu (23/10/2026). Edge Function `usuarios` com a trava; `Regras.podeVerExecutivo` com 7 testes. **Publicada em 23/10/2026** (função `usuarios` versão 3 + push).
- [x] **B2/B3 + C1 Operação** (23/10/2026): drill-down `exIr` e RPCs com RLS/hub; quadrante de Operação completo.
- [x] **C2 Carros Elétricos** (23/10/2026): `exec_eletricos` (`sql/2026-10-23-c2-exec-eletricos.sql`, 7 testes, 93 no banco); KM rodado, Custo total (aluguel pela NF de locação — contrato só como "previsto" depois da última NF —, recargas e manutenção, com composição), Saídas "Sem dados" (D4), custo por km só quando km e recargas cobrem o mesmo período (`Regras.coberturaCustoKm`), KM por hub. **Achado:** recargas são lançadas à mão e pararam em 06/10/2026; telemetria de km só desde 12/10/2026 — custo por km de outubro fica bloqueado com o motivo na tela.
- [x] **C4 Financeiro** (23/10/2026): `exec_financeiro` (`sql/2026-10-23-c4-exec-financeiro.sql`, 3 testes, 96 no banco) + `Regras.resumoFinanceiro` (16 testes, 92 na tela). Competência; mês fechado a partir do dia 05 do mês seguinte; mês atual × média dos 3 últimos fechados; projeção = realizado fechado + média × meses restantes; gastos por linha de conta do período (traço de orçado pronto para a D1). Tela Financeiro ganhou filtros de linha de conta e competência (destino do clique). Em 23/10/2026: jan–set R$ 10,59 mi, projeção 2026 ≈ R$ 14,48 mi. **Fechamento dinâmico (decisão do Jefferson, 23/10/2026):** o dia 05 só define quando o mês passa a contar como fechado (entra na média); o mês nunca é congelado — nota lançada depois, com competência daquele mês, soma na hora no realizado, na média e na projeção (a tela recalcula das notas a cada carga; não há total gravado).
- [x] **C3 Multas** (27/10/2026): `exec_multas` (`sql/2026-10-23-c3-exec-multas.sql`, 5 testes, 101 no banco) + `Regras.motivoDaDescricao`/`classificarMotivo` (116 testes na tela). Multas no período, fila da liderança (192), % infrator identificado, ranking por hub, principais motivos agrupados, ranking de motoristas "Sem dados" (D2). Nome do motorista nunca sai como motivo. Tela de Multas ganhou filtros (hub, status, motivo, mês/ano). **Visão Executiva com os 4 quadrantes.**
- [ ] D; A3 e A4 no fim.

## O que encontrei antes de planejar

1. **Não existe `css/tokens.css`.** Os tokens (cores, fontes, raios, espaços) estão dentro do `<style>` do `index.html` e repetidos no `checklist.html` (regra do CLAUDE.md: os dois blocos são idênticos).
2. **Causa do vazamento das tabelas:** para o cabeçalho da tabela ficar "grudado" no topo ao rolar, o CSS desliga a rolagem horizontal do card (`.frota-sticky-card-body .table-wrap{ overflow:visible }` e `.sticky-table-card > .table-wrap{ overflow:visible }`). Sem rolagem, uma tabela larga (Cadastro da Frota tem 11 colunas) sai da tela. Além disso, o menu lateral não se recolhe no celular (pendência já conhecida).
3. **Dados que faltam no banco para a Visão Executiva** (contagem de hoje):

| KPI pedido | Situação no banco |
|---|---|
| Disponibilidade, preventivas em atraso, km excedente por contrato | **Dados existem** (`veiculos`, `v_revisoes_status`, `v_cadastro_frota`, `v_pool_km_contrato`) |
| Utilização (planejado × realizado) | **Vazio**: `planejamento_picos` = 0 linhas, `rotas_realizadas` = 0 linhas |
| Gastos por linha de conta: realizado | **Existe**: 1.165 notas fiscais (jan/2025 a out/2026), todas com categoria |
| Gastos por linha de conta: orçado | **Vazio**: as 12 categorias têm `orcado_mensal`/`orcado_anual` em branco |
| Multas: motivos | **Fraco**: `codigo_enquadramento` vazio nas 459 multas; o motivo só está em texto livre (`descricao`) |
| Multas: ranking de motoristas | **Vazio**: `motorista_identificado_id` vazio nas 459 (pendência já conhecida) |
| Multas: ranking por hub | **Existe**: as 459 têm `hub_id` |
| Elétricos: km, custo, recargas no mês | **Existe** (telemetria só desde 12/10/2026; 330 recargas) |
| Elétricos: TCO × combustão | **Vazio**: `parametros_combustao_equivalente` = 0 linhas; aluguel/manutenção por carro vêm de contratos/OS |

Decisão sugerida: KPI sem dado aparece como cartão **"Sem dados — falta X"** (nunca número inventado), e o preenchimento desses dados vira etapa própria.

## Pontos para o Jefferson decidir

- **Cores exatas da Beep:** preciso dos códigos (hex) do manual de marca, ou de um arquivo/link com a identidade visual. Sem isso não dá para "acertar a cor exata".
- **Visão Executiva como tela inicial para todos?** Sugestão: tela inicial só para quem tiver o novo módulo `executivo` (diretoria e admin); os demais continuam caindo no primeiro módulo deles.
- **Quem vê o quê:** a diretoria verá números de Financeiro e Multas. Sugestão: a Visão Executiva mostra só os quadrantes dos módulos que a pessoa já pode ver (o banco continua decidindo, pelo RLS).
- **Filtro de hub:** Manutenções/Qualidade têm filtro por hub; diretoria normalmente vê tudo. Confirmar que os perfis de diretoria serão admin ou terão todos os hubs.
- **Origem do orçado e do planejado:** planilha que você manda (importação) ou digitação numa tela nova?

---

## Fase A — Base visual (CSS/tokens e layout)

Cada etapa = 1 commit pequeno, conferido no navegador (claro e escuro, desktop e celular) antes da próxima.

**A1. Separar os tokens em `css/tokens.css`.**
Mover o bloco de tokens para o arquivo novo e carregá-lo no `index.html` e no `checklist.html` (acaba a cópia duplicada). Nenhum valor muda nesta etapa — a tela deve ficar idêntica. Teste: abrir os dois arquivos e comparar com prints de antes.

**A2. Corrigir o vazamento das tabelas.**
Dar à `.table-wrap` uma rolagem horizontal própria e manter o cabeçalho fixo de outro jeito (cabeçalho fixo dentro de uma área com altura máxima, ou cabeçalho fixo só quando a tabela cabe na tela). Também: `min-width:0` nos itens do layout em grade/flex que hoje "esticam" o conteúdo. Teste: Cadastro da Frota, Manutenções, Multas, Financeiro e Dash em tela estreita (1024px e 390px) — nada sai do card.

**A3. Cores da Beep + sombras e tipografia.**
Trocar os valores de `--accent`, `--paper`, `--ink` etc. pelas cores oficiais (depende das cores que você mandar), revisar o modo escuro, sombras mais suaves nos cards, escala de fonte enxuta. Unificar os "meio-passos" (`--fs-sm-2`, `--raio-md-2`, `--raio-md-3`…) em menos tokens. Teste: contraste mínimo de leitura (WCAG AA) nos pares texto/fundo; conferir os 10 painéis e o `checklist.html`.

**A4. Espaçamento consistente.**
Revisar `padding`/`gap` dos cards, cabeçalhos e formulários para usar só a escala `--espaco-*`; trocar números soltos que restarem. Teste: busca no código por `px` fora dos tokens (lista do que ficou de propósito).

**A5. Menu lateral no celular.**
Menu recolhível (botão ☰) abaixo de ~900px, conteúdo ocupando a largura toda. Teste: celular real e 390px no navegador.

**A6. Componentes base para o dashboard.**
Criar no CSS os blocos que a Visão Executiva vai usar: grade de 4 quadrantes (2×2 no desktop, 1 coluna no celular), cartão de KPI clicável (com foco de teclado e cursor), estado "Sem dados", barra simples, mini-gráfico. Reaproveitar o que já existe no Dash de Manutenção (`.gm-*`). Teste: página de exemplo em `testes/` sem dados reais.

---

## Fase B — Visão Executiva (estrutura)

**B1. Módulo e permissão.**
Novo módulo `executivo` em `usuarios_perfil` (tela Gerenciar acessos ganha a opção) e painel `data-panel="executivo"`, primeiro do menu para quem o tem. Seletor de período no topo (mês atual / ano / escolher mês) e de hub.

**B2. Drill-down (clique leva à tela com filtro).**
Função única `irPara(modulo, filtros)` que troca de painel e aplica os filtros já existentes daquela tela (ex.: Cadastro da Frota com filtro `km_excedente` e contrato X). Onde a tela de destino não tiver o filtro necessário, ele é criado na própria tela operacional. Teste: cada clique abre a tela certa já filtrada; botão "← Voltar à Visão Executiva".

**B3. Números pelo banco, em uma chamada por quadrante.**
Uma função SQL por quadrante (`exec_operacao`, `exec_financeiro`, `exec_multas`, `exec_eletricos`), `security invoker` (o RLS de quem está logado vale) e `hub_liberado` onde o módulo tem hub — mesmo padrão do `dash_manutencao`. Migration em `sql/` com data. Cada regra de cálculo nova vai para `regras.js` e/ou para `testes/regras.test.sql`, com teste.

---

## Fase C — Quadrantes (um por vez, na ordem dos dados disponíveis)

**C1. Operação** (dados já existem, exceto utilização)
- Disponibilidade: disponíveis × indisponíveis (agora e tendência de `frota_status_diario`) → clica: Cadastro da Frota filtrado por status.
- **Detalhe dos indisponíveis (em manutenção)** — pedido do Jefferson, 23/10/2026. Ao clicar em "indisponíveis", lista por carro com:

  | Campo pedido | De onde vem hoje | O que falta |
  |---|---|---|
  | Quando parou | `ordens_servico.data_parou` | — |
  | Tempo aguardando agendamento | **não existe** | Histórico de mudança de status da OS (tabela nova `os_status_historico`, gravada por gatilho a cada troca de status). Só mede **daqui para frente**: o passado não tem registro. Até lá, mostra "desde a abertura" como aproximação, avisando. |
  | Tempo aguardando execução do serviço | **não existe** | Mesmo histórico acima (tempo em `aguardando_orcamento`/`aguardando_peca` etc. até `em_execucao`). |
  | Previsão de retorno | `ordens_servico.previsao_retorno` | — |
  | Status de liberação | `ordens_servico.status` + `data_liberacao` | Definir com o Jefferson o texto de cada situação (ex.: "Em reparo", "Pronto, aguardando retirada", "Liberado"). |
  | Serviço executado | parcial: `motivo`, `observacoes`, itens do checklist da OS e peças | Talvez campo próprio "serviço executado" (texto) preenchido ao concluir — confirmar. |
  | Tratativa com a oficina (observações/histórico do auxiliar) | **não existe** como histórico (`observacoes` é um texto só, sobrescrito) | Tabela nova `os_tratativas` (OS, quem, quando, texto), só acrescenta, ninguém apaga; RLS de Manutenções + hub; quem opera Manutenções/Checklist escreve, Diretoria só lê. |

  Esse detalhe também serve à tela de Manutenções (não só à Diretoria). Migration própria + testes em `regras.test.sql` (tempos por fase).
  **Aprovado pelo Jefferson (23/10/2026):** criar o histórico de status da OS (`os_status_historico`) e a tratativa como histórico imutável (`os_tratativas`: quem, quando, o quê; ninguém edita nem apaga). **Status de liberação:** campo próprio com 4 opções — Aguardando orçamento/aprovação, Em reparo, Pronto, aguardando retirada, Liberado (OS concluída vira Liberado sozinha). **Serviço executado:** campo de texto próprio, resumo limpo escrito pelo auxiliar.
  **Banco feito em 23/10/2026** (`sql/2026-10-23-c1-historico-os-tratativas.sql`): colunas `servico_executado` e `status_liberacao`, tabelas `os_status_historico` e `os_tratativas` (RLS de Manutenções + hub; imutáveis até para o dono do banco), view `v_os_fases` (tempo em cada status). 19 testes novos em `regras.test.sql` (81 no total, todos ok). "Foto inicial" das 16 OS em aberto **gravada em 23/10/2026** com aprovação do Jefferson (`sql/2026-10-23-c1-historico-os-foto-inicial.sql`: 15 aguardando_agendamento, 1 aguardando_orcamento, origem `implantacao`).
  **Tela de Manutenções feita em 23/10/2026:** no detalhe da OS, Status de liberação e Serviço executado no formulário; "Tratativas com a oficina" (lista + Adicionar, só quem opera Manutenções; Visualizador só lê) e "Histórico de status" (quem mudou, quando, quanto tempo em cada fase). 
  **Quadrante de Operação feito em 23/10/2026 (B2 + B3 + C1):** `exec_operacao` e `exec_indisponiveis` (`sql/2026-10-23-c1-exec-operacao.sql`, 5 testes novos, 86 no banco); disponibilidade com medidor (disponíveis, indisponíveis, em mobilização, a desmobilizar), preventivas em atraso, contratos com km excedente e barras por contrato, Utilização "Sem dados". Clique na disponibilidade abre os carros indisponíveis (parado há, tempo por fase, previsão vencida em vermelho, liberação, serviço executado, última tratativa; placa abre a OS). **Definição (confirmada pelo Jefferson, 23/10/2026):** aguardando execução = Aguardando orçamento + Aguardando peça (só a oficina); **Aguardando pagamento é mostrado separado** (em laranja) — demora ali é falha do processo interno, não da oficina.
- Preventivas em atraso: contagem de vencidas/vencendo (`v_revisoes_status`) → clica: Dash de Manutenção, lista de revisões.
- Contratos: km excedente por contrato (`v_pool_km_contrato`) → clica no contrato: lista das placas daquele contrato.
- Utilização: planejado × realizado → **"Sem dados"** até as etapas D4 (realizado) e D5 (planejado). **Nova regra (Jefferson, 23/10/2026):**
  - **Realizado = telemetria.** Carro com pelo menos uma viagem registrada no dia = carro utilizado no dia. Elétricos pela Questar (D4); combustão pela telemetria do outro fornecedor (D6, a definir). Até D6, a Utilização mostra só os elétricos, avisando que a combustão está "Sem dados" (nunca soma parcial como se fosse o total). O checklist de Retirada **deixa de ser** a medida de uso (o motorista pode esquecer de preencher); continua valendo para qualidade/anomalias e para a trava de devolução.
  - **Planejado = consulta do Metabase** com as agendas/rotas programadas por dia (integração D5).
  - Indicador: por dia e hub, carros planejados × carros com viagem; no mês, média diária e % de aderência. Regra de cálculo em `regras.js`/SQL com teste.
  - As tabelas antigas `planejamento_picos` e `rotas_realizadas` (vazias) ficam sem uso por enquanto (não apagar).

**C2. Carros Elétricos** (km, custo e recargas existem)
- KM rodado no mês (`telemetria_diaria`), custo total no mês (`recargas_eletricas.valor`), quantidade de saídas no mês.
  - "Saídas": viagens da telemetria Questar (D4), mesma fonte da Utilização. Enquanto D4 não estiver no ar, o cartão mostra "Sem dados" (não usa mais Retirada como substituto — decisão de 23/10/2026).
- TCO × combustão → **"Sem dados"** até D3. Fórmula proposta (para aprovar): custo por km elétrico = (aluguel + recargas + manutenção) ÷ km; combustão = mesma soma com combustível estimado pela autonomia e preço do litro da tabela de parâmetros.
- Também resolve a pendência antiga do card "Integração em teste".

**C3. Multas** (só hub existe hoje)
- Ranking por hub (quantidade e valor) → clica: Multas filtradas pelo hub.
- Principais motivos: lista agrupada por `descricao` normalizada, provisória até D2.
- Ranking de motoristas → **"Sem dados"** até D2.
- Observação: o CLAUDE.md registra que o dashboard de Multas foi deixado para "fase 2 — só com pedido do Jefferson". Este pedido conta como esse "sim".

**C4. Financeiro** (realizado existe, orçado não)
- Gastos por linha de conta (categoria): realizado do mês e do ano (`notas_fiscais` por `mes_referencia`) × orçado → orçado como "Sem dados" até D1.
- Fechamento do mês atual: realizado até hoje + notas lançadas a vencer.
- Projeção de fechamento do ano: realizado até o mês anterior + média dos últimos 3 meses × meses restantes (fórmula a aprovar; vai para `regras.js` com teste).
- Clica na categoria → Financeiro filtrado por categoria e mês (filtro novo na tela de Notas Fiscais).

---

## Fase D — Completar os dados que faltam (cada um depende de você)

- **D1.** Orçado por categoria (mensal/anual): importação de planilha. (O planejado da Utilização saiu daqui e foi para D5.)
- **D2.** Multas: ligar `motorista_identificado_id` nas 459 multas antigas (casar o nome do texto com o cadastro, com lista para você conferir antes do UPDATE) e preencher código/motivo da infração.
- **D3.** Parâmetros de combustão (autonomia km/l, preço do litro, CO₂) por hub.
- **D4.** Carros Elétricos — **percentual de bateria** e **eventos de saída** virão por integração com a API de telemetria (decisão do Jefferson, 23/10/2026). **API confirmada:** a mesma Questar/Exodus do `sync-telemetria-questar`, ação `get_vehicle_trips_extended` (doc: https://exodus-api-doc.app.questar.io/docs/get_vehicle_trips_extended/). Token: segredo `QUESTAR_API_TOKEN`, já no projeto (lido só dentro da Edge Function). Detalhes da documentação:
  - `POST https://app.questar.io/v2/questar-units/api`, `action.name = "get_vehicle_trips_extended"`; filtro por `vehicle_id` (até 100), `license_number` ou `driver_id`; `from_date`/`to_date` com no máximo **32 dias**; até 2.000 viagens por página (`has_more`); a sessão da paginação vence em ~30 min.
  - Cada viagem = uma **saída**: `drive_id` (chave para não duplicar), `license_number`, `start_time`/`end_time`, `distance`, `start_mileage`/`total_mileage`, `energy_type`.
  - **Bateria:** a documentação **não tem campo de bateria**; o mais próximo é `start_fuel_level_percent`/`end_fuel_level_percent`. Primeiro passo: chamar para 1 carro elétrico e conferir se esses campos trazem a carga (%) — se vierem vazios, o % de bateria continua vindo do checklist.
  - **Dados pessoais e localização (aprovado, 23/10/2026):** **não gravar** latitude/longitude nem endereço — não há rastreamento de mapa, só dados de uso. Gravar só o `driver_code` para ligar à matrícula; tabela nova `telemetria_viagens` com RLS (Cadastro da Frota/Carros Elétricos + Visão Executiva), sem acesso anônimo.
  - **Escopo: só os carros elétricos** (corrigido pelo Jefferson em 23/10/2026 — a Questar só está nos elétricos; a combustão vai pela D6). Carro sem telemetria aparece como "sem telemetria", nunca como "não utilizado".
  - Sincronização: junto do cron diário das 02:00 (dia anterior), com reprocessamento idempotente por `drive_id`; chamadas em lotes de até 100 `vehicle_id`. O % de bateria continua vindo do checklist enquanto o campo de nível não for confirmado.
  - **Teste do campo de nível: aprovado** — consultar 1 carro elétrico e conferir `start_fuel_level_percent`/`end_fuel_level_percent`.
- **D4b. Carga retroativa (backfill) da telemetria Questar** (pedido do Jefferson, 23/10/2026): os elétricos rodam desde **fevereiro/2026** (notas de locação da EvoMob desde então), mas `telemetria_diaria` só tem dados desde 12/10/2026. Criar um script único (Edge Function, ação manual, idempotente por veículo + dia) que puxe da Questar o histórico de **01/02/2026 a 12/10/2026** e preencha `telemetria_diaria` (km por carro por dia) — e, junto com a D4, as viagens (saídas). A API aceita no máximo **32 dias por chamada** e 100 veículos: ~9 janelas mensais × 1 lote (60 elétricos); respeitar a paginação (2.000 por página, sessão de 30 min). Conferir antes com 1 carro e 1 semana. Depois do backfill, a telemetria cobre o ano inteiro e o aviso "telemetria desde 12/10" some. **Observação:** o custo por km de outubro só destrava quando as recargas também estiverem completas (relatório do cartão de recarga, também na fase D).
  **Andamento (27/10/2026):** tabela `telemetria_viagens` criada (sem localização nem nomes) e Edge Function `backfill-questar` publicada (modos `teste` e `gravar`; janela ≤ 32 dias; paginação; novas tentativas em erro temporário; pausa de 0,4 s entre chamadas; para em 110 s e devolve o que faltou; idempotente por `drive_id`; não mexe em `km_atual`; não sobrescreve dias da sincronização diária). Testes só de leitura: formato confirmado (48 campos; lat/long/endereço/nome descartados); **horários vêm em UTC**; **nível de bateria vem vazio** (bateria continua pelo checklist); setembro inteiro = 6.115 viagens, 36.433 km, 57 carros, 40 s, sem erros. **Gravado em 27/10/2026 (aprovado pelo Jefferson):** 13.621 viagens, 88.671 km, de **14/05/2026** a 12/10/2026 — mai 323 viagens/2.835 km (6 carros), jun 578/5.721 (6), jul 944/8.791 (12), ago 2.182/12.274 (36), set 6.120/36.434 (57), out (1–12) 3.474/22.616 (51). **Fevereiro a abril: a Questar não tem viagens** (mesmo com notas da EvoMob desde fev — equipamento instalado depois ou fora da retenção da Questar; os 60 elétricos do cadastro são os atuais, nenhum devolvido). 85 viagens sem hodômetro. **Defeito corrigido na função (v4):** o km do dia era recalculado só com as viagens da consulta, e a API filtra por data UTC — 10 carro-dias (495 km) ficaram incompletos em `telemetria_diaria`; agora o dia é recalculado com todas as viagens gravadas. Os 10 carro-dias já gravados foram corrigidos por UPDATE aprovado pelo Jefferson em 27/10/2026 (10 linhas; agosto 12.274 km e setembro 36.434 km, iguais à soma das viagens). **Achado na sincronização diária atual** (`sync-telemetria-questar`): agrupa o dia pela data UTC (viagem que termina depois das 21h de Brasília cai no dia seguinte) e grava o mesmo hodômetro final em todos os dias da janela — corrigir em etapa própria.
- **D4c. Corrigir a sincronização diária da Questar (`sync-telemetria-questar`)** — aprovado pelo Jefferson em 27/10/2026, para fazer **logo depois do backfill (D4b)**. Dois defeitos achados no teste do backfill: (1) o dia da viagem é a data do texto da API, que está em **UTC** — viagem que termina depois das 21h de Brasília cai no dia seguinte; (2) `km_hodometro_fim` recebe o hodômetro da última viagem da janela inteira em **todos** os dias. Correção: usar a mesma leitura do backfill (UTC → dia de Brasília; hodômetro final de cada dia), passar a gravar também em `telemetria_viagens` (saídas diárias para a Visão Executiva) e manter a atualização de `veiculos.km_atual` só com o hodômetro mais recente. Depois, reprocessar de 12/10 em diante para acertar os dias já gravados (mostrar o comando antes, porque altera dado real).
- **D5.** **Integração Metabase — planejado da Utilização** (decisão de 23/10/2026). É a pendência "Integração Pipefy e Metabase: aguardando credenciais" do CLAUDE.md.
  - **Endereço:** https://dados.beepapp.com.br · **Pergunta (consulta) nº 11296** (informados pelo Jefferson, 23/10/2026).
  - **Formato da resposta:** colunas `data_visita`, `bu` e **uma coluna por hub** (ex.: Vila Olímpia, Tatuapé, Alphaville…) com o **número de rotas planejadas**. Usar só as linhas em que `bu` = **"Total do dia"**; cada coluna de hub vira uma linha (dia, hub, rotas planejadas).
  - **Cuidados:** (1) o nome da coluna precisa casar com `hubs.nome` — tabela de-para (nome no Metabase → hub_id), e coluna sem par vira aviso, não é descartada em silêncio; (2) hub novo no Metabase = coluna nova, a leitura não pode depender de lista fixa de colunas; (3) **1 rota planejada = 1 carro** operando naquele hub no dia (confirmado pelo Jefferson, 23/10/2026): Utilização = carros com viagem ÷ rotas planejadas.
  - **Credencial:** acesso só de leitura (usuário de serviço ou chave de API do Metabase), guardado nos segredos da Edge Function — nunca no código nem no chat. Ainda falta o Jefferson providenciar.
  - Sincronização diária por Edge Function + cron (próximos dias e reprocessa os últimos), gravando em tabela nova `utilizacao_planejada` (dia, hub_id, rotas, sincronizado_em) com RLS.
- **D6.** **Telemetria dos carros a combustão** — fornecedor **a definir** (o Jefferson envia na fase D). Mesmo desenho da D4: viagens por dia, só dados de uso (sem localização), token nos segredos da Edge Function, tabela com RLS.

Comandos que alteram dados reais seguem a regra: mostro o comando exato, com `WHERE` por id, e espero sua aprovação.

---

## Ao fim de cada etapa

1. Rodar `testes/regras.test.html` e `testes/regras.test.sql`.
2. Conferir no navegador (claro/escuro, desktop/celular) e nos perfis admin e operador com hubs limitados.
3. Commit pequeno em português. Push só com seu "sim".
4. Atualizar o CLAUDE.md e marcar `[x]` no backlog.

## Ordem sugerida

A1 → A2 → A3 → A4 → A5 → A6 → B1 → B2 → B3 → C1 → C2 → C3 → C4, com D1–D3 em paralelo, conforme você conseguir os dados.
