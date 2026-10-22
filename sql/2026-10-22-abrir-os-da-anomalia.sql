-- "Abrir OS" a partir de uma anomalia do checklist (Onda 2, aprovado pelo Jefferson em 22/10/2026).
-- - A OS é criada pelo formulário normal de OS; as anomalias escolhidas (do MESMO carro) ganham os_id e
--   status 'em_reparo'. Várias anomalias podem ir para a mesma OS.
-- - OS concluída: o painel PERGUNTA, anomalia por anomalia, se a OS resolveu (resolvida) ou se o
--   problema continua (volta para 'aberta'). Nada é resolvido sozinho.
-- - OS cancelada: as anomalias ligadas voltam para 'aberta' automaticamente (cancelar não conserta nada).
-- checklist_anomalias.os_id (com FK para ordens_servico) já existia desde a fase 1.

-- só liga anomalia a OS do mesmo veículo
create or replace function frota.tg_anomalia_os_mesmo_veiculo() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.os_id is not null and new.os_id is distinct from old.os_id
     and (select veiculo_id from ordens_servico where id = new.os_id) is distinct from new.veiculo_id then
    raise exception 'A OS escolhida é de outro veículo.';
  end if;
  return new;
end $$;
create trigger anomalia_os_mesmo_veiculo before update of os_id on frota.checklist_anomalias
  for each row execute function frota.tg_anomalia_os_mesmo_veiculo();

-- OS cancelada → anomalias em reparo ligadas a ela voltam para 'aberta'
create or replace function frota.tg_os_cancelada_reabre_anomalias() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.status = 'cancelada' and old.status is distinct from 'cancelada' then
    update checklist_anomalias set status = 'aberta' where os_id = new.id and status = 'em_reparo';
  end if;
  return new;
end $$;
create trigger os_cancelada_reabre_anomalias after update of status on frota.ordens_servico
  for each row execute function frota.tg_os_cancelada_reabre_anomalias();

-- v_anomalias_abertas: + status da OS ligada (null para quem não vê Manutenções — RLS da OS)
create or replace view frota.v_anomalias_abertas with (security_invoker = true) as
 SELECT a.id, a.veiculo_id, v.placa, v.modelo, v.hub_id, a.grupo, a.item_codigo,
    i.descricao AS item_descricao, a.subtipo, a.descricao, a.severidade, a.status, a.os_id,
    a.created_at AS reportada_em, CURRENT_DATE - a.created_at::date AS dias_aberta, a.checklist_id,
    ( SELECT max(c2.enviado_em) FROM frota.checklist_anomalias x JOIN frota.checklists c2 ON c2.id = x.checklist_id
       WHERE x.origem_anomalia_id = a.id AND x.confirmacao = 'continua'::text) AS ultima_confirmacao,
    c.colaborador_nome, c.tipo AS checklist_tipo, i.grupo_nome,
    ( SELECT f.storage_path FROM frota.checklist_fotos f WHERE f.anomalia_id = a.id ORDER BY f.created_at LIMIT 1) AS foto_path,
    os.status AS os_status
   FROM frota.checklist_anomalias a
     JOIN frota.checklists c ON c.id = a.checklist_id AND c.status = 'enviado'::frota.status_checklist
     JOIN frota.veiculos v ON v.id = a.veiculo_id
     LEFT JOIN frota.checklist_itens_catalogo i ON i.codigo = a.item_codigo
     LEFT JOIN frota.ordens_servico os ON os.id = a.os_id
  WHERE a.nova AND (a.status = ANY (ARRAY['aberta'::frota.status_anomalia, 'em_reparo'::frota.status_anomalia]));
