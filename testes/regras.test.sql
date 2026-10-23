-- =============================================================================
-- Testes das regras de cálculo que ficam NO BANCO (Ferramenta da Frota)
-- =============================================================================
-- Como rodar: cole o arquivo inteiro no SQL Editor do Supabase e clique em Run.
--
-- O que ele faz:
--   1. cria registros FICTÍCIOS (locadora, hub, contratos, veículos, checklists e
--      anomalias, todos com nome "TESTE"/placa "ZZT…");
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
  sa uuid; sb uuid; os1 uuid; os2 uuid;
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
