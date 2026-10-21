-- Checklist de Veículo — Fases 3 e 5: módulo "Qualidade da Frota" no index.html.

-- 1) Quem vê checklist (módulo 'checklist' ou 'manutencao') precisa ler veículos e hubs:
--    as views são security_invoker e herdam o RLS de quem consulta. veiculos não tem PII.
create policy visualizar_veiculos_checklist on frota.veiculos for select to authenticated
  using (frota.posso_ver_checklist());
create policy visualizar_hubs_checklist on frota.hubs for select to authenticated
  using (frota.posso_ver_checklist());

-- 2) Resolver/descartar anomalia pelo painel: registra quem e quando, no servidor.
alter table frota.checklist_anomalias add column resolvida_por uuid;

create or replace function frota.tg_anomalia_resolucao() returns trigger
language plpgsql set search_path = frota as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('resolvida','descartada') then
      new.resolvida_em := coalesce(new.resolvida_em, now());
      new.resolvida_por := coalesce(auth.uid(), new.resolvida_por);
    elsif new.status in ('aberta','em_reparo') then
      new.resolvida_em := null; new.resolvida_por := null;
    end if;
  end if;
  return new;
end $$;
create trigger anomalia_resolucao before update of status on frota.checklist_anomalias
  for each row execute function frota.tg_anomalia_resolucao();

-- 3) v_anomalias_abertas: colunas novas no fim (create or replace só permite acrescentar no fim).
create or replace view frota.v_anomalias_abertas with (security_invoker = true) as
select a.id, a.veiculo_id, v.placa, v.modelo, v.hub_id, a.grupo, a.item_codigo, i.descricao as item_descricao,
       a.subtipo, a.descricao, a.severidade, a.status, a.os_id, a.created_at as reportada_em,
       (current_date - a.created_at::date) as dias_aberta, a.checklist_id,
       (select max(c2.enviado_em) from frota.checklist_anomalias x join frota.checklists c2 on c2.id = x.checklist_id
         where x.origem_anomalia_id = a.id and x.confirmacao = 'continua') as ultima_confirmacao,
       c.colaborador_nome, c.tipo as checklist_tipo, i.grupo_nome,
       (select f.storage_path from frota.checklist_fotos f where f.anomalia_id = a.id order by f.created_at limit 1) as foto_path
  from frota.checklist_anomalias a
  join frota.checklists c on c.id = a.checklist_id and c.status = 'enviado'
  join frota.veiculos v on v.id = a.veiculo_id
  left join frota.checklist_itens_catalogo i on i.codigo = a.item_codigo
 where a.nova and a.status in ('aberta','em_reparo');
