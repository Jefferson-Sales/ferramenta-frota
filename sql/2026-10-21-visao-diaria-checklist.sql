-- Visão Diária de Checklist (21/10/2026).
-- "Deveria ter feito" = veículo ativo com status 'disponivel' no começo do dia (o status já sai de
-- 'disponivel' quando há OS aberta com data de parada; também exclui indisponível manual,
-- mobilização, desmobilizar e devolvido). Como o status só existe "agora", uma foto da lista é
-- gravada todo dia às 00:05 (horário de Brasília). "Fez" = checklist de RETIRADA enviado no dia
-- (Devolução e Inspeção técnica não contam — decisão do Jefferson).

-- ---------------------------------------------------------------- foto diária
create table frota.checklist_frota_esperada (
  dia            date not null,
  veiculo_id     uuid not null references frota.veiculos(id) on delete cascade,
  hub_id         uuid references frota.hubs(id),
  status_no_dia  frota.status_veiculo not null,
  primary key (dia, veiculo_id)
);
-- dias em que a foto foi gerada (permite distinguir "0 carros" de "foto não gerada")
create table frota.checklist_frota_esperada_dias (
  dia        date primary key,
  gerado_em  timestamptz not null default now(),
  qtd        int not null
);
alter table frota.checklist_frota_esperada enable row level security;
alter table frota.checklist_frota_esperada_dias enable row level security;
create policy ver on frota.checklist_frota_esperada for select
  using (frota.posso_ver_checklist() and frota.hub_liberado(hub_id));
create policy ver on frota.checklist_frota_esperada_dias for select
  using (frota.posso_ver_checklist());
grant select on frota.checklist_frota_esperada, frota.checklist_frota_esperada_dias to authenticated;
grant all on frota.checklist_frota_esperada, frota.checklist_frota_esperada_dias to service_role;
-- (sem policy de escrita: só a função abaixo grava)

-- Grava a lista do dia uma única vez (rodar de novo no mesmo dia não muda nada).
create or replace function frota.gerar_frota_esperada(p_dia date default (now() at time zone 'America/Sao_Paulo')::date)
returns int language plpgsql security definer set search_path = frota as $$
declare n int;
begin
  if exists (select 1 from checklist_frota_esperada_dias where dia = p_dia) then
    return -1;
  end if;
  insert into checklist_frota_esperada (dia, veiculo_id, hub_id, status_no_dia)
  select p_dia, v.id, v.hub_id, v.status from veiculos v where v.ativo and v.status = 'disponivel';
  get diagnostics n = row_count;
  insert into checklist_frota_esperada_dias (dia, qtd) values (p_dia, n);
  return n;
end $$;
revoke all on function frota.gerar_frota_esperada(date) from public, anon, authenticated;
grant execute on function frota.gerar_frota_esperada(date) to service_role;

-- 00:05 e (só se falhou) 06:00 em Brasília = 03:05 e 09:00 UTC
select cron.schedule('frota-esperada-0005', '5 3 * * *', $c$ select frota.gerar_frota_esperada(); $c$);
select cron.schedule('frota-esperada-0600', '0 9 * * *', $c$ select frota.gerar_frota_esperada(); $c$);

-- ---------------------------------------------------------------- visão de um dia
-- security invoker: respeita o RLS de quem chama (hubs liberados, módulos).
create or replace function frota.checklist_visao_diaria(p_dia date)
returns table (
  veiculo_id uuid, placa text, modelo text, hub_id uuid,
  na_lista boolean, fez boolean,
  retirada_em timestamptz, qtd_retiradas int, preenchido_por text,
  resultado frota.resultado_checklist, anomalias_novas int,
  ultima_retirada_antes timestamptz, entrou_em_os_em timestamptz
)
language sql stable security invoker set search_path = frota as $$
  with lim as (
    select (p_dia::timestamp at time zone 'America/Sao_Paulo') as ini,
           ((p_dia + 1)::timestamp at time zone 'America/Sao_Paulo') as fim
  ),
  ret as (
    select c.veiculo_id, min(c.enviado_em) as primeira, count(*)::int as qtd,
           (array_agg(c.colaborador_nome order by c.enviado_em))[1] as quem,
           (array_agg(c.resultado order by c.enviado_em desc))[1] as resultado,
           sum(c.qtd_anomalias_novas)::int as anom
      from checklists c, lim
     where c.status = 'enviado' and c.tipo = 'retirada'
       and c.enviado_em >= lim.ini and c.enviado_em < lim.fim
     group by c.veiculo_id
  ),
  esp as (select e.veiculo_id, e.hub_id from checklist_frota_esperada e where e.dia = p_dia),
  base as (select esp.veiculo_id from esp union select ret.veiculo_id from ret)
  select v.id, v.placa, v.modelo, coalesce(esp.hub_id, v.hub_id),
         esp.veiculo_id is not null, ret.veiculo_id is not null,
         ret.primeira, coalesce(ret.qtd, 0), ret.quem, ret.resultado, coalesce(ret.anom, 0),
         (select max(c2.enviado_em) from checklists c2, lim
           where c2.veiculo_id = v.id and c2.status = 'enviado' and c2.tipo = 'retirada' and c2.enviado_em < lim.ini),
         (select min(o.data_parou) from ordens_servico o, lim
           where o.veiculo_id = v.id and o.status <> 'cancelada' and o.data_parou >= lim.ini and o.data_parou < lim.fim)
    from base
    join veiculos v on v.id = base.veiculo_id
    left join esp on esp.veiculo_id = v.id
    left join ret on ret.veiculo_id = v.id
$$;
revoke all on function frota.checklist_visao_diaria(date) from public, anon;
grant execute on function frota.checklist_visao_diaria(date) to authenticated, service_role;

-- primeira foto: o dia da implantação (tirada à tarde, não às 00:05)
select frota.gerar_frota_esperada();
