-- =============================================================================
-- Testes das regras de cálculo que ficam NO BANCO (Ferramenta da Frota)
-- =============================================================================
-- Como rodar: cole o arquivo inteiro no SQL Editor do Supabase e clique em Run.
--
-- O que ele faz:
--   1. cria registros FICTÍCIOS (locadora, hub, contratos, veículos, checklists e
--      anomalias, todos com nome "TESTE"/placa "ZZT…"; na seção 9, também 4 logins
--      fictícios "teste.…@zzt.invalid" para simular quem clica em Feita/Não feita);
--   2. lê as mesmas views e chama as mesmas funções que o sistema usa;
--   3. compara cada resultado com o valor esperado;
--   4. termina com RAISE EXCEPTION, que DESFAZ TUDO o que foi criado.
--
-- Por isso o resultado aparece como uma "mensagem de erro" vermelha — isso é o
-- esperado. Leia a primeira linha: "TESTES: N ok, 0 falha" = tudo certo.
-- Nada fica gravado e nenhum e-mail de alerta sai (o pedido de envio do gatilho
-- também é desfeito junto com a transação).
--
-- Não precisa de extensão nem de nada instalado. Rodar como está (usuário do SQL Editor).
-- =============================================================================
do $$
declare
  casos text[] := '{}'; obtidos text[] := '{}'; esperados text[] := '{}';
  forn uuid; hub uuid;
  c_pool uuid; c_vencido uuid; c_sem_data uuid; c_30 uuid; c_31 uuid;
  v1 uuid; v2 uuid; v3 uuid; v_inativo uuid; v_venc uuid; v_sd uuid; v_30 uuid; v_31 uuid;
  vc uuid; vd uuid; ck uuid; a_alta uuid; a_crit uuid; a uuid;
  ta uuid; tb uuid; r1 uuid; r2 uuid; dv uuid;
  sa uuid; sb uuid; os1 uuid; os2 uuid; rv uuid; os3 uuid;
  hub2 uuid; u_op uuid; u_outro uuid; u_vis uuid; u_adm uuid; cf uuid; cv uuid;
  vh uuid; osh uuid; osf uuid; tr uuid;
  hub3 uuid; vi1 uuid; vi2 uuid; osi uuid; j jsonb;
  hub4 uuid; c_el uuid; ve1 uuid; ve2 uuid; vcb uuid;
  cat_t uuid; hub5 uuid; vm uuid; hub6 uuid; hub7 uuid; vr1 uuid; vr2 uuid; vr3 uuid; vr4 uuid;
  grupos jsonb := (select jsonb_agg(distinct grupo) from frota.checklist_itens_catalogo where ativo and 'retirada' = any(tipos) and (combustiveis is null or 'combustao' = any(combustiveis)));
  x text; res text; n_ok int := 0; n_falha int := 0; linhas text := '';
begin
  -- ---------------------------------------------------------------- dados base
  insert into frota.fornecedores (nome, tipo) values ('TESTE Locadora', 'locadora') returning id into forn;
  insert into frota.hubs (nome) values ('TESTE Hub') returning id into hub;

  -- Contrato pool: 2.000 km/mês × 12 meses × 3 carros = 72.000 km; R$ 0,50 por km excedente
  insert into frota.contratos (locadora_id, numero_contrato, franquia_km_mensal, prazo_locacao_meses, quantidade_veiculos,
                               valor_km_excedente, cobranca_km_excedente, data_fim, status)
  values (forn, 'TESTE POOL', 2000, 12, 3, 0.50, 'POOL', current_date + 100, 'ativo') returning id into c_pool;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, ativo) values ('ZZT0A01', hub, c_pool, 30000, true) returning id into v1;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, ativo) values ('ZZT0A02', hub, c_pool, 25000, true) returning id into v2;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, ativo) values ('ZZT0A03', hub, c_pool, 20000, true) returning id into v3;
  -- carro inativo do mesmo contrato: NÃO pode entrar na soma do pool
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, ativo) values ('ZZT0A04', hub, c_pool, 99999, false) returning id into v_inativo;

  -- Contratos para o status calculado (vencido / ≤30 dias / >30 dias / sem data)
  insert into frota.contratos (locadora_id, numero_contrato, data_fim) values (forn, 'TESTE VENCIDO', current_date - 1) returning id into c_vencido;
  insert into frota.contratos (locadora_id, numero_contrato, data_fim) values (forn, 'TESTE 30 DIAS', current_date + 30) returning id into c_30;
  insert into frota.contratos (locadora_id, numero_contrato, data_fim) values (forn, 'TESTE 31 DIAS', current_date + 31) returning id into c_31;
  insert into frota.contratos (locadora_id, numero_contrato, data_fim) values (forn, 'TESTE SEM DATA', null) returning id into c_sem_data;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual) values ('ZZT0B01', hub, c_vencido, 1000) returning id into v_venc;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual) values ('ZZT0B02', hub, c_30, 1000) returning id into v_30;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual) values ('ZZT0B03', hub, c_31, 1000) returning id into v_31;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual) values ('ZZT0B04', hub, c_sem_data, 1000) returning id into v_sd;

  -- ============================================ 1. KM EXCEDENTE POR VEÍCULO
  -- total contratado = franquia mensal × prazo = 2.000 × 12 = 24.000
  select trim_scale(total_km_contratado)::text into x from frota.v_cadastro_frota where veiculo_id = v1;
  casos := casos || text 'km por veículo: total contratado (2.000 × 12)'; obtidos := obtidos || x; esperados := esperados || text '24000';
  select trim_scale(km_excedente)::text into x from frota.v_cadastro_frota where veiculo_id = v1;
  casos := casos || text 'km por veículo: rodou 30.000 → excedente +6.000'; obtidos := obtidos || x; esperados := esperados || text '6000';
  select trim_scale(km_excedente)::text into x from frota.v_cadastro_frota where veiculo_id = v3;
  casos := casos || text 'km por veículo: rodou 20.000 → sobra (−4.000)'; obtidos := obtidos || x; esperados := esperados || text '-4000';
  select coalesce(trim_scale(km_excedente)::text, 'vazio') into x from frota.v_cadastro_frota where veiculo_id = v_venc;
  casos := casos || text 'km por veículo: contrato sem franquia → sem cálculo'; obtidos := obtidos || x; esperados := esperados || text 'vazio';

  -- ============================================ 2. KM EXCEDENTE DO CONTRATO (POOL)
  select trim_scale(km_contratado_pool)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: contratado (2.000 × 12 × 3 carros)'; obtidos := obtidos || x; esperados := esperados || text '72000';
  select trim_scale(km_usado_pool)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: usado = soma só dos carros ativos (30k+25k+20k)'; obtidos := obtidos || x; esperados := esperados || text '75000';
  select qtde_veiculos_ativos::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: conta só carros ativos'; obtidos := obtidos || x; esperados := esperados || text '3';
  select trim_scale(km_excedente_pool)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: excedente (75.000 − 72.000)'; obtidos := obtidos || x; esperados := esperados || text '3000';
  select trim_scale(pct_utilizado_pool)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: % utilizado (75.000 / 72.000)'; obtidos := obtidos || x; esperados := esperados || text '104.2';
  select trim_scale(custo_estimado_excedente)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: custo estimado (3.000 km × R$ 0,50)'; obtidos := obtidos || x; esperados := esperados || text '1500';
  update frota.veiculos set km_atual = 10000 where id in (v1, v2, v3);
  select trim_scale(custo_estimado_excedente)::text || ' / ' || trim_scale(km_excedente_pool)::text into x from frota.v_pool_km_contrato where contrato_id = c_pool;
  casos := casos || text 'pool: abaixo da franquia → custo 0, saldo negativo'; obtidos := obtidos || x; esperados := esperados || text '0 / -42000';

  -- ============================================ 3. STATUS DO CONTRATO (calculado)
  select status_contrato_calc into x from frota.v_cadastro_frota where veiculo_id = v_venc;
  casos := casos || text 'contrato: venceu ontem → vencido'; obtidos := obtidos || x; esperados := esperados || text 'vencido';
  select status_contrato_calc into x from frota.v_cadastro_frota where veiculo_id = v_30;
  casos := casos || text 'contrato: vence em 30 dias → critico'; obtidos := obtidos || x; esperados := esperados || text 'critico';
  select status_contrato_calc into x from frota.v_cadastro_frota where veiculo_id = v_31;
  casos := casos || text 'contrato: vence em 31 dias → ativo'; obtidos := obtidos || x; esperados := esperados || text 'ativo';
  select status_contrato_calc into x from frota.v_cadastro_frota where veiculo_id = v_sd;
  casos := casos || text 'contrato: sem data de fim → sem_data'; obtidos := obtidos || x; esperados := esperados || text 'sem_data';

  -- ============================================ 4. RESULTADO DO CHECKLIST (pior anomalia aberta)
  insert into frota.veiculos (placa, hub_id, km_atual) values ('ZZT0C01', hub, 5000) returning id into vc;

  -- 4a. sem nenhuma anomalia → ok
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'retirada', 5000, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'freios_pneus', false);
  casos := casos || text 'checklist: tudo OK → ok'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'ok';

  -- 4b. anomalia nova ALTA (com foto) → reparo_necessario
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'devolucao', 5100, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'freios_pneus', true);
  insert into frota.checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, severidade, nova) values (ck, vc, 'freios_pneus', 'rd_pneus', 'alta', true) returning id into a_alta;
  insert into frota.checklist_fotos (checklist_id, anomalia_id, tipo, storage_path) values (ck, a_alta, 'anomalia', 'ZZT0C01/' || ck || '/a.jpg');
  casos := casos || text 'checklist: anomalia alta → reparo_necessario'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'reparo_necessario';
  select qtd_anomalias_novas::text into x from frota.checklists where id = ck;
  casos := casos || text 'checklist: conta 1 anomalia nova'; obtidos := obtidos || x; esperados := esperados || text '1';

  -- 4c. outro checklist com anomalia CRÍTICA → urgente (a alta continua aberta, mas a pior manda)
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'retirada', 5200, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'carroceria_limpeza', true);
  insert into frota.checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, severidade, nova) values (ck, vc, 'carroceria_limpeza', 'rd_avaria', 'critica', true) returning id into a_crit;
  insert into frota.checklist_fotos (checklist_id, anomalia_id, tipo, storage_path) values (ck, a_crit, 'anomalia', 'ZZT0C01/' || ck || '/b.jpg');
  casos := casos || text 'checklist: crítica + alta abertas → urgente'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'urgente';

  -- 4d. "não existe mais" na crítica → volta a valer a alta → reparo_necessario
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'devolucao', 5300, '0000') returning id into ck;
  insert into frota.checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, severidade, nova, origem_anomalia_id, confirmacao)
    values (ck, vc, 'carroceria_limpeza', 'rd_avaria', 'critica', false, a_crit, 'nao_existe');
  casos := casos || text 'checklist: crítica "não existe mais" → reparo_necessario'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'reparo_necessario';
  select status::text into x from frota.checklist_anomalias where id = a_crit;
  casos := casos || text 'checklist: "não existe mais" fecha a anomalia original'; obtidos := obtidos || x; esperados := esperados || text 'resolvida';

  -- 4e. alta marcada como resolvida (como no botão do painel) + nova BAIXA → atencao
  update frota.checklist_anomalias set status = 'resolvida' where id = a_alta;
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'retirada', 5400, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'carroceria_limpeza', true);
  insert into frota.checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, severidade, nova) values (ck, vc, 'carroceria_limpeza', 'rd_limpeza', 'baixa', true) returning id into a;
  insert into frota.checklist_fotos (checklist_id, anomalia_id, tipo, storage_path) values (ck, a, 'anomalia', 'ZZT0C01/' || ck || '/c.jpg');
  casos := casos || text 'checklist: só anomalia baixa aberta → atencao'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'atencao';

  -- 4f. anomalia DESCARTADA não conta → ok
  update frota.checklist_anomalias set status = 'descartada' where id = a;
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vc, 'devolucao', 5500, '0000') returning id into ck;
  casos := casos || text 'checklist: anomalia descartada não conta → ok'; obtidos := obtidos || frota.finalizar_checklist(ck)::text; esperados := esperados || text 'ok';

  -- ============================================ 5. CHECKLIST RECUSADO (validações do envio)
  insert into frota.veiculos (placa, hub_id, km_atual) values ('ZZT0C02', hub, 100) returning id into vd;

  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vd, 'retirada', 100, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'freios_pneus', true);
  insert into frota.checklist_anomalias (checklist_id, veiculo_id, grupo, item_codigo, severidade, nova) values (ck, vd, 'freios_pneus', 'rd_freio', 'alta', true);
  begin res := frota.finalizar_checklist(ck)::text; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Anomalia nova sem foto%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'recusa: anomalia nova sem foto'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vd, 'retirada', 100, '0000') returning id into ck;
  insert into frota.checklist_grupos (checklist_id, grupo, tem_anomalia) values (ck, 'freios_pneus', true);
  begin res := frota.finalizar_checklist(ck)::text; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Grupo marcado com problema sem anomalia%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'recusa: grupo "tem problema" sem anomalia'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  -- a ordem das fotos que faltam na mensagem varia; o teste só confere que recusou pelas fotos certas
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vd, 'inspecao_tecnica', 100, '0000') returning id into ck;
  insert into frota.checklist_fotos (checklist_id, tipo, storage_path) values (ck, 'painel', 'ZZT0C02/' || ck || '/painel.jpg');
  begin res := frota.finalizar_checklist(ck)::text; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Faltam fotos obrigatórias:%' and sqlerrm like '%frontal%' and sqlerrm like '%traseira%' and sqlerrm not like '%painel%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'recusa: inspeção técnica sem foto frontal e traseira'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula) values (vd, 'retirada', 100, '0000') returning id into ck;
  perform frota.finalizar_checklist(ck);
  begin res := frota.finalizar_checklist(ck)::text; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Checklist já foi enviado%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'recusa: enviar o mesmo checklist duas vezes'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  -- ============================================ 6. TRAVA DE DEVOLUÇÃO (registrar_checklist)
  insert into frota.veiculos (placa, hub_id, km_atual) values ('ZZT0D01', hub, 100) returning id into ta;
  insert into frota.veiculos (placa, hub_id, km_atual) values ('ZZT0D02', hub, 100) returning id into tb;
  r1 := gen_random_uuid();
  perform frota.registrar_checklist(jsonb_build_object('id', r1, 'tipo','retirada','veiculo_id',ta,'km',100,'colaborador_matricula','T9001','grupos',grupos));
  begin perform frota.registrar_checklist(jsonb_build_object('id', gen_random_uuid(), 'tipo','retirada','veiculo_id',tb,'km',100,'colaborador_matricula','T9001','grupos',grupos)); x := 'aceitou';
  exception when others then x := case when sqlerrm like 'Devolução pendente do carro ZZT0D01%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'trava: retirada de outro carro com retirada aberta'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  r2 := gen_random_uuid();
  perform frota.registrar_checklist(jsonb_build_object('id', r2, 'tipo','retirada','veiculo_id',ta,'km',110,'colaborador_matricula','T9001','grupos',grupos));
  select fechada_como into x from frota.checklists where id = r1;
  casos := casos || text 'trava: refazer retirada do mesmo carro substitui a anterior'; obtidos := obtidos || x; esperados := esperados || text 'nova_retirada_mesmo_carro';
  perform frota.registrar_checklist(jsonb_build_object('id', gen_random_uuid(), 'tipo','devolucao','veiculo_id',ta,'km',120,'colaborador_matricula','T9002','grupos',grupos));
  select coalesce((select placa from frota.retirada_pendente('T9001', tb)), 'nenhuma') into x;
  casos := casos || text 'trava: devolução por OUTRO motorista não libera'; obtidos := obtidos || x; esperados := esperados || text 'ZZT0D01';
  dv := gen_random_uuid();
  perform frota.registrar_checklist(jsonb_build_object('id', dv, 'tipo','devolucao','veiculo_id',ta,'km',130,'colaborador_matricula','T9001','grupos',grupos));
  select fechada_como || case when fechada_por_checklist = dv then ' (ligada)' else '' end into x from frota.checklists where id = r2;
  casos := casos || text 'trava: devolução do próprio motorista fecha a retirada'; obtidos := obtidos || x; esperados := esperados || text 'devolucao (ligada)';
  select coalesce((select placa from frota.retirada_pendente('T9001', tb)), 'nenhuma') into x;
  casos := casos || text 'trava: depois da devolução, libera outro carro'; obtidos := obtidos || x; esperados := esperados || text 'nenhuma';
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula, status, enviado_em) values (ta, 'retirada', 1, 'T9003', 'enviado', frota.trava_devolucao_desde() - interval '1 hour');
  select coalesce((select placa from frota.retirada_pendente('T9003', tb)), 'nenhuma') into x;
  casos := casos || text 'trava: retirada de antes da implantação não trava'; obtidos := obtidos || x; esperados := esperados || text 'nenhuma';

  -- ============================================ 7. OS × STATUS DO VEÍCULO (sinistro parou / continua rodando)
  insert into frota.veiculos (placa, hub_id, km_atual, status) values ('ZZT0E01', hub, 100, 'disponivel') returning id into sa;
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, veiculo_parado)
    values (sa, 'sinistro', 'aguardando_agendamento', now(), false) returning id into os1;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'sinistro "continua rodando": carro segue disponível'; obtidos := obtidos || x; esperados := esperados || text 'disponivel';
  update frota.ordens_servico set veiculo_parado = true where id = os1;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'sinistro trocado para "parou": carro fica indisponível'; obtidos := obtidos || x; esperados := esperados || text 'indisponivel';
  update frota.ordens_servico set veiculo_parado = false where id = os1;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'sinistro de volta para "continua rodando": carro volta a disponível'; obtidos := obtidos || x; esperados := esperados || text 'disponivel';
  -- sem resposta (OS antigas): conta como parado, igual a antes
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou) values (sa, 'sinistro', 'aguardando_agendamento', now()) returning id into os2;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'sinistro sem resposta: conta como parado'; obtidos := obtidos || x; esperados := esperados || text 'indisponivel';
  -- duas OS segurando o carro (os1 vira parada de novo): concluir uma não libera
  update frota.ordens_servico set veiculo_parado = true where id = os1;
  update frota.ordens_servico set status = 'concluida' where id = os2;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'duas OS paradas: concluir uma mantém indisponível'; obtidos := obtidos || x; esperados := esperados || text 'indisponivel';
  update frota.ordens_servico set status = 'cancelada' where id = os1;
  select status::text into x from frota.veiculos where id = sa;
  casos := casos || text 'duas OS paradas: fechar a última libera'; obtidos := obtidos || x; esperados := esperados || text 'disponivel';
  -- carro indisponível por outro motivo (sem OS): abrir OS que não para o carro não pode liberá-lo
  insert into frota.veiculos (placa, hub_id, km_atual, status) values ('ZZT0E02', hub, 100, 'indisponivel') returning id into sb;
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, veiculo_parado) values (sb, 'sinistro', 'aguardando_agendamento', now(), false);
  select status::text into x from frota.veiculos where id = sb;
  casos := casos || text 'carro já indisponível + OS "continua rodando": não libera'; obtidos := obtidos || x; esperados := esperados || text 'indisponivel';
  insert into frota.ordens_servico (veiculo_id, tipo, status) values (sb, 'preventiva', 'agendada');
  select status::text into x from frota.veiculos where id = sb;
  casos := casos || text 'carro já indisponível + OS agendada: não libera'; obtidos := obtidos || x; esperados := esperados || text 'indisponivel';

  -- ============================================ 8. REVISÃO PREVENTIVA (aviso, itens do plano, OS concluída)
  casos := casos || text 'revisão: 48.999 km, marco 50.000 → em_dia'; obtidos := obtidos || frota.situacao_revisao(48999, 50000, true); esperados := esperados || text 'em_dia';
  casos := casos || text 'revisão: 49.000 km (1.000 antes) → vencendo'; obtidos := obtidos || frota.situacao_revisao(49000, 50000, true); esperados := esperados || text 'vencendo';
  casos := casos || text 'revisão: 50.000 km → vencida'; obtidos := obtidos || frota.situacao_revisao(50000, 50000, true); esperados := esperados || text 'vencida';
  casos := casos || text 'revisão: modelo sem plano → sem_plano'; obtidos := obtidos || frota.situacao_revisao(90000, 10000, false); esperados := esperados || text 'sem_plano';
  casos := casos || text 'revisão: marco 110.000 usa os itens de 10.000'; obtidos := obtidos || frota.marco_no_plano(110000)::text; esperados := esperados || text '10000';
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0F01', hub, 39500, 'disponivel', 'KWID') returning id into rv;
  insert into frota.revisoes_a_conferir (veiculo_id, marco_km, motivo) values (rv, 40000, 'sem_registro');
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, km_entrada, marco_km)
    values (rv, 'preventiva', 'aguardando_agendamento', now(), 39500, 40000) returning id into os3;
  select string_agg(item, ' | ' order by ordem) into x from frota.os_checklist_itens where os_id = os3;
  casos := casos || text 'OS preventiva 40k (KWID): já nasce com os 10 itens do marco'; obtidos := obtidos || (select count(*)::text from frota.os_checklist_itens where os_id = os3); esperados := esperados || text '10';
  casos := casos || text 'OS preventiva 40k: inclui discos, não inclui correia'; obtidos := obtidos || (case when x like '%Discos de freio%' and x not like '%Correia%' then 'ok' else x end); esperados := esperados || text 'ok';
  update frota.os_checklist_itens set concluido = true where os_id = os3 and item in ('Óleo + filtro de óleo', 'Discos de freio');
  update frota.ordens_servico set status = 'concluida', data_liberacao = now() where id = os3;
  select marco_km || ' / ' || origem || ' / ' || array_to_string(itens_trocados, ', ') into x from frota.revisoes_preventivas where veiculo_id = rv;
  casos := casos || text 'OS preventiva concluída grava a revisão com os itens marcados'; obtidos := obtidos || x; esperados := esperados || text '40000 / os / Óleo + filtro de óleo, Discos de freio';
  select status into x from frota.revisoes_a_conferir where veiculo_id = rv and marco_km = 40000;
  casos := casos || text 'OS preventiva concluída marca o marco "a conferir" como feito'; obtidos := obtidos || x; esperados := esperados || text 'feita';
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0F02', hub, 100, 'disponivel', 'BYD - Mini Dolphin GL') returning id into rv;
  insert into frota.ordens_servico (veiculo_id, tipo, status, km_entrada, marco_km) values (rv, 'preventiva', 'agendada', 100, 10000) returning id into os3;
  casos := casos || text 'OS preventiva de modelo sem plano: sem itens automáticos'; obtidos := obtidos || (select count(*)::text from frota.os_checklist_itens where os_id = os3); esperados := esperados || text '0';

  -- ============================================ 9. LISTA "A CONFERIR" (botões Feita / Não feita → conferir_revisao)
  -- usuários fictícios (somem no fim, junto com o resto); cada caso "entra" como um deles pelo request.jwt.claims
  insert into frota.hubs (nome) values ('TESTE Hub 2') returning id into hub2;
  u_op := gen_random_uuid(); u_outro := gen_random_uuid(); u_vis := gen_random_uuid(); u_adm := gen_random_uuid();
  insert into auth.users (id, email, aud, role) values
    (u_op, 'teste.op@zzt.invalid', 'authenticated', 'authenticated'), (u_outro, 'teste.outro@zzt.invalid', 'authenticated', 'authenticated'),
    (u_vis, 'teste.vis@zzt.invalid', 'authenticated', 'authenticated'), (u_adm, 'teste.adm@zzt.invalid', 'authenticated', 'authenticated');
  insert into frota.usuarios_perfil (user_id, nome, papel, modulos_visualizacao, modulos_operador) values
    (u_op, 'TESTE Operador', 'operador', '{manutencao}', '{manutencao}'),
    (u_outro, 'TESTE Operador Outro Hub', 'operador', '{manutencao}', '{manutencao}'),
    (u_vis, 'TESTE Visualizador', 'visualizador', '{manutencao}', '{}'),
    (u_adm, 'TESTE Admin', 'admin', '{}', '{}');
  insert into frota.usuarios_hubs (user_id, hub_id) values (u_op, hub), (u_outro, hub2), (u_vis, hub);
  -- carro KWID com a 10k da planilha e 20k/30k/40k "a conferir"
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0G01', hub, 25000, 'disponivel', 'KWID') returning id into cv;
  insert into frota.revisoes_preventivas (veiculo_id, marco_km, data_revisao, origem) values (cv, 10000, current_date - 200, 'planilha');
  insert into frota.revisoes_a_conferir (veiculo_id, marco_km, motivo, anotacao) values
    (cv, 10000, 'duplicada_divergente', 'TESTE já na planilha'), (cv, 20000, 'sem_registro', null),
    (cv, 30000, 'proxima_indicada', null), (cv, 40000, 'nao_fez', null);

  -- visualizador não confere
  perform set_config('request.jwt.claims', json_build_object('sub', u_vis, 'role', 'authenticated')::text, true);
  select id into cf from frota.revisoes_a_conferir where veiculo_id = cv and marco_km = 20000;
  begin res := frota.conferir_revisao(cf, true, null, null); x := 'aceitou'; exception when others then x := case when sqlerrm like 'Sem permissão%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'a conferir: visualizador não pode marcar'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  -- operador de outro hub não confere
  perform set_config('request.jwt.claims', json_build_object('sub', u_outro, 'role', 'authenticated')::text, true);
  begin res := frota.conferir_revisao(cf, true, null, null); x := 'aceitou'; exception when others then x := case when sqlerrm like 'Veículo fora dos seus hubs%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'a conferir: operador de outro hub não pode marcar'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  -- operador do hub: data no futuro é recusada
  perform set_config('request.jwt.claims', json_build_object('sub', u_op, 'role', 'authenticated')::text, true);
  begin res := frota.conferir_revisao(cf, true, current_date + 2, null); x := 'aceitou'; exception when others then x := case when sqlerrm like 'A data da revisão não pode ser no futuro%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'a conferir: data no futuro é recusada'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  select status into x from frota.revisoes_a_conferir where id = cf;
  casos := casos || text 'a conferir: recusas não mudam o item'; obtidos := obtidos || x; esperados := esperados || text 'a_conferir';
  -- Feita com data
  res := frota.conferir_revisao(cf, true, current_date - 10, ' confirmado com a oficina ');
  select status || ' / ' || (conferido_por = u_op)::text || ' / ' || conferido_obs into x from frota.revisoes_a_conferir where id = cf;
  casos := casos || text 'Feita: item vira feita, com quem conferiu e observação'; obtidos := obtidos || x; esperados := esperados || text 'feita / true / confirmado com a oficina';
  select origem || ' / ' || (data_revisao = current_date - 10)::text || ' / ' || (observacao like 'Conferido por TESTE Operador%')::text into x
    from frota.revisoes_preventivas where veiculo_id = cv and marco_km = 20000;
  casos := casos || text 'Feita: grava a revisão (origem manual, data informada)'; obtidos := obtidos || coalesce(x, 'nada gravado'); esperados := esperados || text 'manual / true / true';
  select proximo_marco::text into x from frota.v_revisoes_status where veiculo_id = cv;
  casos := casos || text 'Feita: próximo marco passa para 30.000'; obtidos := obtidos || coalesce(x, 'carro não aparece'); esperados := esperados || text '30000';
  -- conferir o mesmo item de novo
  begin res := frota.conferir_revisao(cf, false, null, null); x := 'aceitou'; exception when others then x := case when sqlerrm like 'Este marco já foi conferido%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'a conferir: item já conferido não muda de novo'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  -- Feita sem data
  select id into cf from frota.revisoes_a_conferir where veiculo_id = cv and marco_km = 30000;
  res := frota.conferir_revisao(cf, true, null, null);
  select coalesce(data_revisao::text, 'sem data') into x from frota.revisoes_preventivas where veiculo_id = cv and marco_km = 30000;
  casos := casos || text 'Feita sem data: revisão gravada "sem data"'; obtidos := obtidos || coalesce(x, 'nada gravado'); esperados := esperados || text 'sem data';
  -- Não feita
  select id into cf from frota.revisoes_a_conferir where veiculo_id = cv and marco_km = 40000;
  res := frota.conferir_revisao(cf, false, null, null);
  select status || ' / ' || (select count(*) from frota.revisoes_preventivas where veiculo_id = cv and marco_km = 40000)::text into x from frota.revisoes_a_conferir where id = cf;
  casos := casos || text 'Não feita: item vira nao_feita, sem revisão gravada'; obtidos := obtidos || x; esperados := esperados || text 'nao_feita / 0';
  -- admin confere em qualquer hub; marco que já está na planilha não é sobrescrito
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  select id into cf from frota.revisoes_a_conferir where veiculo_id = cv and marco_km = 10000;
  res := frota.conferir_revisao(cf, true, current_date, null);
  select origem || ' / ' || (data_revisao = current_date - 200)::text into x from frota.revisoes_preventivas where veiculo_id = cv and marco_km = 10000;
  casos := casos || text 'Feita (admin): não sobrescreve revisão que veio da planilha'; obtidos := obtidos || x; esperados := esperados || text 'planilha / true';
  perform set_config('request.jwt.claims', '', true);

  -- ============================================ 10. HISTÓRICO DE STATUS DA OS, STATUS DE LIBERAÇÃO E TRATATIVAS (C1)
  insert into frota.veiculos (placa, hub_id, km_atual, status) values ('ZZT0H01', hub, 1000, 'disponivel') returning id into vh;
  perform set_config('request.jwt.claims', json_build_object('sub', u_op, 'role', 'authenticated')::text, true);
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou) values (vh, 'corretiva', 'aguardando_agendamento', now()) returning id into osh;
  select count(*) || ' / ' || coalesce(max(valor_anterior), 'nulo') || ' → ' || max(valor_novo) || ' / ' || max(mudou_por_nome) into x
    from frota.os_status_historico where os_id = osh and campo = 'status';
  casos := casos || text 'histórico: OS nova grava o status inicial e quem abriu'; obtidos := obtidos || x; esperados := esperados || text '1 / nulo → aguardando_agendamento / TESTE Operador';
  update frota.ordens_servico set status = 'em_execucao' where id = osh;
  select valor_anterior || ' → ' || valor_novo into x from frota.os_status_historico where os_id = osh and campo = 'status' order by id desc limit 1;
  casos := casos || text 'histórico: troca de status grava de → para'; obtidos := obtidos || x; esperados := esperados || text 'aguardando_agendamento → em_execucao';
  update frota.ordens_servico set status = 'em_execucao', observacoes = 'TESTE só observação' where id = osh;
  select count(*)::text into x from frota.os_status_historico where os_id = osh and campo = 'status';
  casos := casos || text 'histórico: salvar sem mudar o status não grava linha'; obtidos := obtidos || x; esperados := esperados || text '2';
  update frota.ordens_servico set status_liberacao = 'pronto_retirada', servico_executado = 'TESTE troca de pastilhas' where id = osh;
  select coalesce(valor_anterior, 'nulo') || ' → ' || valor_novo into x from frota.os_status_historico where os_id = osh and campo = 'status_liberacao' order by id desc limit 1;
  casos := casos || text 'histórico: status de liberação também é registrado'; obtidos := obtidos || x; esperados := esperados || text 'nulo → pronto_retirada';
  begin update frota.ordens_servico set status_liberacao = 'qualquer' where id = osh; x := 'aceitou'; exception when check_violation then x := 'recusou'; end;
  casos := casos || text 'status de liberação fora das 4 opções é recusado'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  update frota.ordens_servico set status = 'concluida' where id = osh;
  select status_liberacao || ' / ' || servico_executado into x from frota.ordens_servico where id = osh;
  casos := casos || text 'OS concluída: status de liberação vira "liberado" (resumo do serviço fica)'; obtidos := obtidos || x; esperados := esperados || text 'liberado / TESTE troca de pastilhas';
  select string_agg(campo || ':' || valor_novo, ', ' order by id) into x from frota.os_status_historico where os_id = osh and id > (select max(id) - 2 from frota.os_status_historico where os_id = osh);
  casos := casos || text 'OS concluída: histórico tem a conclusão e a liberação'; obtidos := obtidos || x; esperados := esperados || text 'status:concluida, status_liberacao:liberado';
  perform set_config('request.jwt.claims', '', true);
  begin update frota.os_status_historico set valor_novo = 'cancelada' where os_id = osh; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Registro de histórico não pode%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'histórico: ninguém edita (nem o dono do banco)'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  begin delete from frota.os_status_historico where os_id = osh; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Registro de histórico não pode%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'histórico: ninguém apaga'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  -- tempo em cada fase (v_os_fases): trocas simuladas 1 h e 3 h depois da abertura
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou) values (vh, 'corretiva', 'aguardando_orcamento', now()) returning id into osf;
  insert into frota.os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_em) values
    (osf, 'status', 'aguardando_orcamento', 'em_execucao', now() + interval '1 hour'),
    (osf, 'status', 'em_execucao', 'concluida', now() + interval '3 hours');
  select string_agg(valor || '=' || to_char(duracao, 'HH24:MI'), ', ' order by inicio) into x from frota.v_os_fases where os_id = osf and campo = 'status';
  casos := casos || text 'tempo por fase: orçamento 1 h, execução 2 h, concluída não conta'; obtidos := obtidos || x; esperados := esperados || text 'aguardando_orcamento=01:00, em_execucao=02:00, concluida=00:00';
  select string_agg(atual::text, ',' order by inicio) into x from frota.v_os_fases where os_id = osf and campo = 'status';
  casos := casos || text 'tempo por fase: só o último período é o atual'; obtidos := obtidos || x; esperados := esperados || text 'false,false,true';

  -- tratativas, entrando como usuário logado (o RLS vale)
  perform set_config('request.jwt.claims', json_build_object('sub', u_op, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into frota.os_tratativas (os_id, texto, autor_id, autor_nome) values (osh, '  Oficina pediu mais 2 dias para a peça  ', u_adm, 'Alguém Forjado') returning id into tr;
  execute 'reset role';
  select autor_nome || ' / ' || (autor_id = u_op)::text || ' / ' || texto into x from frota.os_tratativas where id = tr;
  casos := casos || text 'tratativa: operador do hub registra; autor e hora vêm do servidor'; obtidos := obtidos || x; esperados := esperados || text 'TESTE Operador / true / Oficina pediu mais 2 dias para a peça';
  execute 'set local role authenticated';
  begin insert into frota.os_tratativas (os_id, texto) values (osh, ' a '); x := 'aceitou'; exception when others then x := 'recusou'; end;
  casos := casos || text 'tratativa: texto curto demais é recusado'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  begin update frota.os_tratativas set texto = 'TESTE editado' where id = tr; get diagnostics x = row_count; x := case when x = '0' then 'recusou' else 'aceitou' end; exception when others then x := 'recusou'; end;
  casos := casos || text 'tratativa: o próprio autor não edita'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', u_vis, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into frota.os_tratativas (os_id, texto) values (osh, 'TESTE visualizador tentando'); x := 'aceitou'; exception when others then x := 'recusou'; end;
  casos := casos || text 'tratativa: visualizador não registra'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  select count(*)::text into x from frota.os_tratativas where os_id = osh;
  casos := casos || text 'tratativa: visualizador do hub lê'; obtidos := obtidos || x; esperados := esperados || text '1';
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', u_outro, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin insert into frota.os_tratativas (os_id, texto) values (osh, 'TESTE outro hub tentando'); x := 'aceitou'; exception when others then x := 'recusou'; end;
  casos := casos || text 'tratativa: operador de outro hub não registra'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  select count(*)::text || ' / ' || (select count(*) from frota.os_status_historico where os_id = osh)::text into x from frota.os_tratativas where os_id = osh;
  casos := casos || text 'operador de outro hub não lê tratativas nem histórico'; obtidos := obtidos || x; esperados := esperados || text '0 / 0';
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  begin delete from frota.os_tratativas where id = tr; x := 'aceitou'; exception when others then x := case when sqlerrm like 'Registro de histórico não pode%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'tratativa: ninguém apaga (nem o dono do banco)'; obtidos := obtidos || x; esperados := esperados || text 'recusou';

  -- ============================================ 11. VISÃO EXECUTIVA — QUADRANTE DE OPERAÇÃO (exec_operacao / exec_indisponiveis)
  -- hub próprio com composição conhecida: 3 disponíveis, 2 indisponíveis (1 com OS parada, 1 sem OS), 1 em mobilização, 1 devolvido (fora da conta)
  insert into frota.hubs (nome) values ('TESTE Hub 3') returning id into hub3;
  insert into frota.veiculos (placa, hub_id, km_atual, status) values
    ('ZZT0J01', hub3, 1, 'disponivel'), ('ZZT0J02', hub3, 1, 'disponivel'), ('ZZT0J03', hub3, 1, 'disponivel'),
    ('ZZT0J06', hub3, 1, 'em_mobilizacao'), ('ZZT0J07', hub3, 1, 'devolvido');
  insert into frota.veiculos (placa, hub_id, km_atual, status) values ('ZZT0J04', hub3, 1, 'disponivel') returning id into vi1;
  insert into frota.veiculos (placa, hub_id, km_atual, status, status_desde) values ('ZZT0J05', hub3, 1, 'indisponivel', now() - interval '3 days') returning id into vi2;
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, previsao_retorno) values (vi1, 'corretiva', 'aguardando_agendamento', now() - interval '2 days', current_date + 3) returning id into osi;
  update frota.ordens_servico set status_liberacao = 'em_reparo', servico_executado = 'TESTE resumo' where id = osi;
  -- trocas simuladas no histórico: 1 h em agendamento, depois 2 h aguardando pagamento
  insert into frota.os_status_historico (os_id, campo, valor_anterior, valor_novo, mudou_em) values
    (osi, 'status', 'aguardando_agendamento', 'aguardando_pagamento', now() + interval '1 hour'),
    (osi, 'status', 'aguardando_pagamento', 'em_execucao', now() + interval '3 hours');
  insert into frota.os_tratativas (os_id, texto) values (osi, 'TESTE primeira tratativa');
  insert into frota.os_tratativas (os_id, texto) values (osi, 'TESTE segunda tratativa');
  j := frota.exec_operacao(hub3) -> 'disponibilidade';
  x := (j->>'total') || ' / ' || (j->>'disponivel') || ' / ' || (j->>'indisponivel') || ' / ' || (j->>'em_mobilizacao');
  casos := casos || text 'exec_operacao: total (sem devolvido) / disponíveis / indisponíveis / em mobilização'; obtidos := obtidos || x; esperados := esperados || text '6 / 3 / 2 / 1';
  j := frota.exec_indisponiveis(hub3);
  select string_agg((e->>'placa') || ':' || case when e->'os' = 'null'::jsonb then 'sem OS' else 'OS' end, ', ' order by e->>'parado_desde') into x from jsonb_array_elements(j) e;
  casos := casos || text 'exec_indisponiveis: parado há mais tempo primeiro; carro sem OS aparece como "sem OS"'; obtidos := obtidos || x; esperados := esperados || text 'ZZT0J05:sem OS, ZZT0J04:OS';
  select (e->'os'->>'status_liberacao') || ' / ' || (e->'os'->>'servico_executado') || ' / ' || (e->'os'->>'tratativas') || ' / ' || (e->'os'->'ultima_tratativa'->>'texto') || ' / ' || (e->'os'->'ultima_tratativa'->>'autor')
    into x from jsonb_array_elements(j) e where e->>'placa' = 'ZZT0J04';
  casos := casos || text 'exec_indisponiveis: liberação, serviço, nº de tratativas e a última (com autor)'; obtidos := obtidos || x; esperados := esperados || text 'em_reparo / TESTE resumo / 2 / TESTE segunda tratativa / TESTE Admin';
  select (e->'os'->>'seg_agendamento') || ' / ' || coalesce(e->'os'->>'seg_espera_execucao', 'nulo') || ' / ' || (e->'os'->>'seg_pagamento') into x from jsonb_array_elements(j) e where e->>'placa' = 'ZZT0J04';
  casos := casos || text 'exec_indisponiveis: agendamento 1 h, aguardando execução vazio, pagamento 2 h (separado)'; obtidos := obtidos || x; esperados := esperados || text '3600 / nulo / 7200';
  -- quem não tem o hub não vê nada (operador de outro hub)
  perform set_config('request.jwt.claims', json_build_object('sub', u_outro, 'role', 'authenticated')::text, true);
  x := (frota.exec_operacao(hub3) -> 'disponibilidade' ->> 'total') || ' / ' || jsonb_array_length(frota.exec_indisponiveis(hub3))::text;
  casos := casos || text 'exec_*: usuário sem o hub vê 0 carros'; obtidos := obtidos || x; esperados := esperados || text '0 / 0';
  perform set_config('request.jwt.claims', '', true);

  -- ============================================ 12. VISÃO EXECUTIVA — CARROS ELÉTRICOS (exec_eletricos)
  -- hub próprio: 2 elétricos e 1 a combustão no mesmo contrato (R$ 3.000/mês por carro); período = março/2026
  insert into frota.hubs (nome) values ('TESTE Hub 4') returning id into hub4;
  insert into frota.contratos (locadora_id, numero_contrato, valor_mensal, data_fim) values (forn, 'TESTE ELETRICOS', 3000, current_date + 300) returning id into c_el;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, status, tipo_combustivel) values ('ZZT0K01', hub4, c_el, 1, 'disponivel', 'eletrico') returning id into ve1;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, status, tipo_combustivel) values ('ZZT0K02', hub4, c_el, 1, 'disponivel', 'eletrico') returning id into ve2;
  insert into frota.veiculos (placa, hub_id, contrato_id, km_atual, status, tipo_combustivel) values ('ZZT0K03', hub4, c_el, 1, 'disponivel', 'combustao') returning id into vcb;
  insert into frota.telemetria_diaria (veiculo_id, data, km_rodado, fonte) values
    (ve1, '2026-03-10', 100.5, 'teste'), (ve2, '2026-03-11', 50, 'teste'), (ve1, '2026-04-01', 999, 'teste');
  insert into frota.recargas_eletricas (veiculo_id, hub_id, data_hora, kwh, valor, fonte) values
    (ve1, hub4, '2026-03-05 10:00-03', 10, 40, 'teste'), (ve2, hub4, '2026-03-31 23:30-03', 15, 60, 'teste'),
    (ve1, hub4, '2026-04-01 00:30-03', 99, 999, 'teste');
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, data_conclusao, valor_total) values (ve1, 'corretiva', 'concluida', '2026-03-18 09:00-03', '2026-03-20 12:00-03', 500);
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, valor_total) values (ve2, 'corretiva', 'cancelada', '2026-03-21 12:00-03', 999);
  insert into frota.ordens_servico (veiculo_id, tipo, status, data_parou, data_conclusao, valor_total) values (vcb, 'corretiva', 'concluida', '2026-03-21 09:00-03', '2026-03-22 12:00-03', 777);
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  j := frota.exec_eletricos('2026-03-01', '2026-03-31', hub4);
  x := (j->>'carros') || ' / ' || (j->'km'->>'total') || ' / ' || (j->'km'->>'carros');
  casos := casos || text 'exec_eletricos: só elétricos; km do período (fora do mês não entra)'; obtidos := obtidos || x; esperados := esperados || text '2 / 150.5 / 2';
  x := (j->'recargas'->>'qtd') || ' / ' || (j->'recargas'->>'valor') || ' / ' || (j->'manutencao'->>'valor');
  casos := casos || text 'exec_eletricos: recargas do mês (23h30 do dia 31 entra; 00h30 do dia 1º não) e manutenção sem OS cancelada nem combustão'; obtidos := obtidos || x; esperados := esperados || text '2 / 100 / 500';
  x := (j->'aluguel'->>'mensal') || ' / ' || (j->'aluguel'->>'meses') || ' / ' || (j->'aluguel'->>'periodo');
  casos := casos || text 'exec_eletricos: aluguel = valor mensal dos 2 elétricos × 1 mês'; obtidos := obtidos || x; esperados := esperados || text '6000 / 1 / 6000';
  j := frota.exec_eletricos('2026-01-01', '2026-03-31', hub4);
  casos := casos || text 'exec_eletricos: janeiro a março = 3 meses de aluguel'; obtidos := obtidos || ((j->'aluguel'->>'meses') || ' / ' || (j->'aluguel'->>'periodo')); esperados := esperados || text '3 / 18000';
  begin j := frota.exec_eletricos('2026-03-31', '2026-03-01', hub4); x := 'aceitou'; exception when others then x := case when sqlerrm like 'Período inválido%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'exec_eletricos: período invertido é recusado'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  -- aluguel pela NF de LOCAÇÃO VEICULAR (locadora só de elétricos): mês antes da última NF sem nota = 0; depois = contrato "previsto"
  update frota.veiculos set locadora_id = forn where id in (ve1, ve2);
  insert into frota.notas_fiscais (fornecedor_id, categoria_id, mes_referencia, valor)
    values (forn, (select id from frota.categorias_custo where nome ilike 'loca%veic%' limit 1), '2031-03-01', 5800);
  j := frota.exec_eletricos('2031-02-01', '2031-04-30') -> 'aluguel';
  x := (j->>'meses_nf') || ' / ' || (j->>'meses_previsto') || ' / ' || (j->>'nf') || ' / ' || ((j->>'periodo')::numeric = 5800 + (j->>'mensal')::numeric)::text;
  casos := casos || text 'aluguel: fev sem NF (antes da última) = 0; mar = NF; abr = contrato previsto'; obtidos := obtidos || x; esperados := esperados || text '1 / 1 / 5800 / true';
  j := frota.exec_eletricos('2031-03-01', '2031-03-31', hub4) -> 'aluguel';
  casos := casos || text 'aluguel com filtro de hub: NF não tem hub, fica o contrato do hub'; obtidos := obtidos || ((j->>'meses_nf') || ' / ' || (j->>'periodo')); esperados := esperados || text '0 / 6000';

  -- ============================================ 13. VISÃO EXECUTIVA — FINANCEIRO (exec_financeiro)
  -- notas em 2032 (sem dado real nesse ano): competência é o mes_referencia, não o vencimento
  insert into frota.categorias_custo (nome) values ('TESTE Categoria') returning id into cat_t;
  insert into frota.notas_fiscais (fornecedor_id, categoria_id, hub_id, mes_referencia, data_vencimento, valor) values
    (forn, cat_t, hub4, '2032-05-01', '2032-06-10', 100),   -- competência maio, vence em junho
    (forn, cat_t, hub4, '2032-05-01', '2032-05-20', 50),
    (forn, cat_t, null, '2032-06-01', '2032-06-10', 30),    -- sem hub
    (forn, cat_t, hub4, '2032-04-01', '2032-04-10', 999);   -- antes de p_desde
  j := frota.exec_financeiro('2032-05-01');
  select string_agg((e->>'mes') || '=' || (e->>'valor') || ' (' || (e->>'qtd') || ')', ', ' order by e->>'mes') into x
    from jsonb_array_elements(j->'linhas') e where e->>'categoria_id' = cat_t::text;
  casos := casos || text 'exec_financeiro: soma por mês de competência a partir de p_desde'; obtidos := obtidos || coalesce(x, 'nada'); esperados := esperados || text '2032-05=150 (2), 2032-06=30 (1)';
  j := frota.exec_financeiro('2032-05-01', hub4);
  select string_agg((e->>'mes') || '=' || (e->>'valor'), ', ' order by e->>'mes') into x
    from jsonb_array_elements(j->'linhas') e where e->>'categoria_id' = cat_t::text;
  casos := casos || text 'exec_financeiro: com hub, nota sem hub fica de fora (e é contada em sem_hub)'; obtidos := obtidos || (coalesce(x, 'nada') || ' / sem_hub>=1: ' || ((j->>'sem_hub')::int >= 1)::text); esperados := esperados || text '2032-05=150 / sem_hub>=1: true';
  select (e->>'orcado_mensal') is null into x from jsonb_array_elements(frota.exec_financeiro('2032-05-01')->'categorias') e where e->>'id' = cat_t::text;
  casos := casos || text 'exec_financeiro: devolve as categorias (orçado vazio até a D1)'; obtidos := obtidos || x; esperados := esperados || text 'true';

  -- ============================================ 14. VISÃO EXECUTIVA — MULTAS (exec_multas)
  -- data da infração em Brasília; o nome do motorista ("Motorista (planilha): …") nunca vira motivo
  insert into frota.hubs (nome) values ('TESTE Hub 5') returning id into hub5;
  insert into frota.veiculos (placa, hub_id, km_atual, status) values ('ZZT0M01', hub5, 1, 'disponivel') returning id into vm;
  insert into frota.multas (veiculo_id, hub_id, data_infracao, data_recebimento_email, valor, status, descricao) values
    (vm, hub5, '2032-05-03 10:00-03', now(), 130.16, 'infrator_identificado', 'TRANSITAR EM VELOCIDADE SUPERIOR A MÁXIMA PERMITIDA EM ATE 20% | Motorista (planilha): FULANO TESTE | Status original planilha: X'),
    (vm, hub5, '2032-05-31 23:30-03', now(), 195.23, 'aguardando_retorno_lideranca', 'Motorista (planilha): FULANO TESTE | Status original planilha: Y'),
    (vm, hub5, '2032-06-01 00:30-03', now(), 999, 'aguardando_retorno_lideranca', 'ESTACIONAR NO PASSEIO | Status original planilha: Z');
  j := frota.exec_multas('2032-05-01', '2032-05-31', hub5);
  x := (j->>'total') || ' / ' || (j->>'valor') || ' / ' || (j->'por_hub'->0->>'n');
  casos := casos || text 'exec_multas: período pela data da infração em Brasília (23h30 do dia 31 entra; 00h30 do dia 1º não)'; obtidos := obtidos || x; esperados := esperados || text '2 / 325.39 / 2';
  select count(*)::text into x from jsonb_array_elements(j->'motivos') e where e->>'texto' ilike '%FULANO%' or e->>'texto' ilike 'motorista%';
  casos := casos || text 'exec_multas: nome do motorista nunca sai como motivo'; obtidos := obtidos || x; esperados := esperados || text '0';
  select string_agg(coalesce(nullif(e->>'texto', ''), '(sem motivo)') || '=' || (e->>'n'), ', ' order by e->>'texto') into x from jsonb_array_elements(j->'motivos') e;
  casos := casos || text 'exec_multas: motivo é o trecho antes do " | "; só nome = sem motivo'; obtidos := obtidos || x; esperados := esperados || text '(sem motivo)=1, TRANSITAR EM VELOCIDADE SUPERIOR A MÁXIMA PERMITIDA EM ATE 20%=1';
  casos := casos || text 'exec_multas: fila da liderança é a atual (todas as datas, só o hub)'; obtidos := obtidos || (j->>'pendentes_lideranca'); esperados := esperados || text '2';
  begin j := frota.exec_multas('2032-05-31', '2032-05-01', hub5); x := 'aceitou'; exception when others then x := case when sqlerrm like 'Período inválido%' then 'recusou' else sqlerrm end; end;
  casos := casos || text 'exec_multas: período invertido é recusado'; obtidos := obtidos || x; esperados := esperados || text 'recusou';
  perform set_config('request.jwt.claims', '', true);

  -- ============================================ 15. DASH — EXCEL ANALÍTICO DO CHECKLIST DE RETIRADA (checklist_retirada_analitico)
  perform set_config('request.jwt.claims', json_build_object('sub', u_adm, 'role', 'authenticated')::text, true);
  insert into frota.hubs (nome) values ('TESTE Hub 6') returning id into hub6;
  insert into frota.hubs (nome) values ('TESTE Hub 7') returning id into hub7;
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0N01', hub6, 1, 'disponivel', 'KWID') returning id into vr1;
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0N02', hub6, 1, 'disponivel', 'KWID') returning id into vr2;
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0N03', hub6, 1, 'disponivel', 'KWID') returning id into vr3;
  insert into frota.veiculos (placa, hub_id, km_atual, status, modelo) values ('ZZT0N04', hub7, 1, 'disponivel', 'KWID') returning id into vr4;
  insert into frota.checklist_frota_esperada_dias (dia, qtd) values ('2032-07-01', 3), ('2032-07-02', 1);
  insert into frota.checklist_frota_esperada (dia, veiculo_id, hub_id, status_no_dia) values
    ('2032-07-01', vr1, hub6, 'disponivel'), ('2032-07-01', vr2, hub6, 'disponivel'), ('2032-07-01', vr4, hub7, 'disponivel'),
    ('2032-07-02', vr1, hub6, 'disponivel');
  -- vr1 fez às 08:15 e de novo às 09:00 (vale a primeira); vr3 fez mas não estava na lista; vr2 só devolução; vr1 no dia 2 às 23:50 (ainda dia 2 em Brasília)
  insert into frota.checklists (veiculo_id, tipo, km, colaborador_matricula, status, enviado_em) values
    (vr1, 'retirada', 1, '0000', 'enviado', '2032-07-01 08:15-03'), (vr1, 'retirada', 1, '0000', 'enviado', '2032-07-01 09:00-03'),
    (vr3, 'retirada', 1, '0000', 'enviado', '2032-07-01 10:00-03'), (vr2, 'devolucao', 1, '0000', 'enviado', '2032-07-01 11:00-03'),
    (vr1, 'retirada', 1, '0000', 'enviado', '2032-07-02 23:50-03');
  select string_agg(a.dia || ' ' || a.placa || ' ' || case when a.realizado then 'Realizado ' || to_char(a.retirada_em at time zone 'America/Sao_Paulo', 'HH24:MI') else 'Não realizado' end, ' | ' order by a.dia, a.placa) into x
    from frota.checklist_retirada_analitico('2032-07-01', '2032-07-02', hub6) a;
  casos := casos || text 'analítico: 1 linha por carro esperado/dia; primeira retirada; devolução não conta; fora da lista não entra'; obtidos := obtidos || x;
  esperados := esperados || text '2032-07-01 ZZT0N01 Realizado 08:15 | 2032-07-01 ZZT0N02 Não realizado | 2032-07-02 ZZT0N01 Realizado 23:50';
  select count(*)::text into x from frota.checklist_retirada_analitico('2032-07-01', '2032-07-01');
  casos := casos || text 'analítico: sem filtro de hub traz os dois hubs'; obtidos := obtidos || x; esperados := esperados || text '3';
  select (select count(*) from frota.checklist_retirada_analitico('2032-07-01', '2032-07-01', hub6)) || '/' || (select count(*) filter (where realizado) from frota.checklist_retirada_analitico('2032-07-01', '2032-07-01', hub6))
      || ' = ' || (select count(*) filter (where na_lista) || '/' || count(*) filter (where na_lista and fez) from frota.checklist_visao_diaria('2032-07-01') v where v.hub_id = hub6) into x;
  casos := casos || text 'analítico: totais iguais aos da Visão diária (mesma regra do Dash)'; obtidos := obtidos || x; esperados := esperados || text '2/1 = 2/1';
  perform set_config('request.jwt.claims', '', true);

  -- ---------------------------------------------------------------- resultado
  for i in 1 .. array_length(casos, 1) loop
    if obtidos[i] is not distinct from esperados[i] then
      n_ok := n_ok + 1; linhas := linhas || E'\n  ok     ' || casos[i];
    else
      n_falha := n_falha + 1;
      linhas := linhas || E'\n  FALHA  ' || casos[i] || '  (esperado: ' || coalesce(esperados[i], 'vazio') || ' | obtido: ' || coalesce(obtidos[i], 'vazio') || ')';
    end if;
  end loop;
  -- desfaz tudo e mostra o resultado
  raise exception 'TESTES: % ok, % falha%', n_ok, n_falha, linhas;
end $$;
