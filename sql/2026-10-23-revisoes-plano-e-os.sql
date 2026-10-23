-- Revisões preventivas (23/10/2026) — parte 3: plano de itens por marco, situação de cada carro e OS de preventiva.

-- 1. Itens por marco de km (sem tela própria: incluir/alterar item = linha nova aqui).
--    PROVISÓRIO: lista passada pelo Jefferson, não é a caderneta oficial Renault — telas mostram "a confirmar".
create table if not exists frota.revisao_itens_plano (
  id uuid primary key default gen_random_uuid(),
  modelo_padrao text not null,          -- comparado com veiculos.modelo via ILIKE (ex.: 'KWID%')
  item text not null,
  marcos integer[] not null,            -- marcos em que o item entra (10000…100000)
  ordem integer not null default 0,
  provisorio boolean not null default true,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);
alter table frota.revisao_itens_plano enable row level security;
create policy visualizar_revisao_itens_plano on frota.revisao_itens_plano for select using (frota.posso_ver('manutencao'));
create policy admin_edita_revisao_itens_plano on frota.revisao_itens_plano for all
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');
grant select on frota.revisao_itens_plano to authenticated;
grant all on frota.revisao_itens_plano to service_role;

insert into frota.revisao_itens_plano (modelo_padrao, item, marcos, ordem)
select 'KWID%', i.item, i.marcos, i.ordem from (values
  ('Óleo + filtro de óleo',        array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 1),
  ('Filtro de ar do motor',        array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 2),
  ('Filtro de combustível',        array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 3),
  ('Filtro de ar-condicionado',    array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 4),
  ('Líquido do radiador',          array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 5),
  ('Alinhamento/balanceamento',    array[10000,20000,30000,40000,50000,60000,70000,80000,90000,100000], 6),
  ('Velas de ignição',             array[20000,40000,60000,80000,100000], 7),
  ('Pastilhas de freio',           array[20000,40000,60000,80000,100000], 8),
  ('Fluido de freio',              array[20000,40000,60000,80000,100000], 9),
  ('Discos de freio',              array[40000,80000], 10),
  ('Correia dentada + correia poly V', array[60000], 11)
) i(item, marcos, ordem)
where not exists (select 1 from frota.revisao_itens_plano);

-- 2. OS de preventiva: km na entrada e marco da revisão
alter table frota.ordens_servico add column if not exists km_entrada numeric;
alter table frota.ordens_servico add column if not exists marco_km integer
  check (marco_km is null or (marco_km >= 10000 and marco_km % 10000 = 0));

-- marco acima de 100k repete o ciclo (110k usa os itens de 10k, 120k os de 20k…)
create or replace function frota.marco_no_plano(p_marco integer) returns integer
language sql immutable as $$ select ((p_marco - 1) % 100000) / 10000 * 10000 + 10000 $$;

-- 3. Situação de revisão por veículo (respeita hubs: security_invoker + hub_liberado explícito, como v_qualidade_frota)
create or replace view frota.v_revisoes_status with (security_invoker = true) as
select v.id as veiculo_id, v.placa, v.modelo, v.hub_id, v.status as status_veiculo,
       exists (select 1 from frota.revisao_itens_plano i where i.ativo and v.modelo ilike i.modelo_padrao) as tem_plano,
       u.marco_km as ultimo_marco, u.data_revisao as ultima_revisao_em,
       coalesce(u.marco_km, 0) + 10000 as proximo_marco,
       greatest(coalesce(v.km_atual, 0), coalesce(ck.km, 0), coalesce(os.km_entrada, 0)) as km_ref,
       case when coalesce(ck.km, 0) > coalesce(v.km_atual, 0) and coalesce(ck.km, 0) >= coalesce(os.km_entrada, 0) then 'checklist'
            when coalesce(os.km_entrada, 0) > coalesce(v.km_atual, 0) then 'os' else 'cadastro' end as km_fonte,
       coalesce(u.marco_km, 0) + 10000 - greatest(coalesce(v.km_atual, 0), coalesce(ck.km, 0), coalesce(os.km_entrada, 0)) as km_faltam,
       (select count(*) from frota.revisoes_a_conferir a where a.veiculo_id = v.id and a.status = 'a_conferir') as marcos_a_conferir,
       os_aberta.id as os_preventiva_aberta
  from frota.veiculos v
  left join lateral (select r.marco_km, r.data_revisao from frota.revisoes_preventivas r
                      where r.veiculo_id = v.id and r.marco_km is not null order by r.marco_km desc limit 1) u on true
  left join lateral (select c.km from frota.checklists c where c.veiculo_id = v.id and c.status = 'enviado'
                      order by c.enviado_em desc limit 1) ck on true
  left join lateral (select o.km_entrada from frota.ordens_servico o where o.veiculo_id = v.id and o.km_entrada is not null
                      order by o.created_at desc limit 1) os on true
  left join lateral (select o.id from frota.ordens_servico o where o.veiculo_id = v.id and o.tipo = 'preventiva'
                      and o.status not in ('concluida', 'cancelada') order by o.created_at desc limit 1) os_aberta on true
 where v.ativo and v.status <> 'devolvido' and frota.hub_liberado(v.hub_id);
grant select on frota.v_revisoes_status to authenticated;

-- regra do aviso (também em regras.js → situacaoRevisao): vencida quando km ≥ marco; vencendo a partir de 1.000 km antes
create or replace function frota.situacao_revisao(p_km numeric, p_proximo integer, p_tem_plano boolean) returns text
language sql immutable as $$
  select case when not p_tem_plano then 'sem_plano'
              when p_km >= p_proximo then 'vencida'
              when p_km >= p_proximo - 1000 then 'vencendo'
              else 'em_dia' end $$;

-- 4. OS de preventiva com marco: já nasce com os itens do plano no checklist da OS
create or replace function frota.tg_os_preventiva_itens() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.tipo = 'preventiva' and new.marco_km is not null then
    insert into os_checklist_itens (os_id, item, ordem, concluido)
    select new.id, i.item, i.ordem, false
      from revisao_itens_plano i join veiculos v on v.id = new.veiculo_id
     where i.ativo and v.modelo ilike i.modelo_padrao and frota.marco_no_plano(new.marco_km) = any(i.marcos)
     order by i.ordem;
  end if;
  return new;
end $$;
create or replace trigger os_preventiva_itens after insert on frota.ordens_servico
  for each row execute function frota.tg_os_preventiva_itens();

-- 5. OS de preventiva concluída → grava a revisão do marco (itens marcados = trocados)
create or replace function frota.tg_os_preventiva_concluida() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.tipo = 'preventiva' and new.marco_km is not null and new.status = 'concluida' and old.status is distinct from 'concluida' then
    insert into revisoes_preventivas (veiculo_id, os_id, marco_km, data_revisao, km_na_revisao, itens_trocados, valor, oficina_id, origem)
    values (new.veiculo_id, new.id, new.marco_km,
            (coalesce(new.data_liberacao, new.data_conclusao, now()) at time zone 'America/Sao_Paulo')::date,
            new.km_entrada,
            (select array_agg(item order by ordem) from os_checklist_itens where os_id = new.id and concluido),
            new.valor_total, new.oficina_id, 'os')
    on conflict (veiculo_id, marco_km) where marco_km is not null do update
      set os_id = excluded.os_id, data_revisao = excluded.data_revisao, km_na_revisao = excluded.km_na_revisao,
          itens_trocados = excluded.itens_trocados, valor = excluded.valor, oficina_id = excluded.oficina_id
      where revisoes_preventivas.origem = 'os';   -- nunca sobrescreve histórico da planilha
    -- o marco "a conferir" desse carro, se houver, passa a feito
    update revisoes_a_conferir set status = 'feita', conferido_em = now(), conferido_obs = 'OS de preventiva concluída'
     where veiculo_id = new.veiculo_id and marco_km = new.marco_km and status = 'a_conferir';
  end if;
  return new;
end $$;
create or replace trigger os_preventiva_concluida after update of status on frota.ordens_servico
  for each row execute function frota.tg_os_preventiva_concluida();
