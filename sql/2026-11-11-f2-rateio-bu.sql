-- Financeiro F2 (aprovado e aplicado em 11/11/2026): rateio do custo da frota por BU (Imunizações / Lab / Infusão)
-- Fonte: "10. Fechamento Mensal - Operações.xlsx", aba "Rateio", bloco "Motoristas" (colunas F a I).
-- A planilha não tem mês: a competência vem do campo "Competência" da tela.
-- A linha "Total" da planilha é gravada com hub_id = null e vale para hub que não está na planilha (hoje MOURISCO) e para "(sem hub)".

create table frota.financeiro_rateio_bu (
  id              uuid primary key default gen_random_uuid(),
  mes_competencia date not null check (mes_competencia = date_trunc('month', mes_competencia)::date),
  hub_id          uuid references frota.hubs(id),          -- null = linha "Total" (média geral)
  bu_nome         text not null check (length(btrim(bu_nome)) between 2 and 40),
  percentual      numeric(9,6) not null check (percentual >= 0 and percentual <= 1),
  arquivo_origem  text,
  importado_em    timestamptz not null default now(),
  importado_por   uuid default auth.uid(),
  constraint financeiro_rateio_bu_unico unique nulls not distinct (mes_competencia, hub_id, bu_nome)
);

alter table frota.financeiro_rateio_bu enable row level security;
revoke all on frota.financeiro_rateio_bu from anon, authenticated;
grant select, insert, update on frota.financeiro_rateio_bu to authenticated;   -- sem delete: ninguém apaga
grant all on frota.financeiro_rateio_bu to service_role;

create policy rateio_bu_ler on frota.financeiro_rateio_bu for select to authenticated
  using (frota.posso_ver('financeiro'));
create policy rateio_bu_gravar on frota.financeiro_rateio_bu for insert to authenticated
  with check (frota.meu_papel() = 'admin');
create policy rateio_bu_corrigir on frota.financeiro_rateio_bu for update to authenticated
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');

-- Conferência: cada hub do mês tem que somar 100% (tolerância de 0,1 ponto). A tela mostra o aviso e não deixa confirmar.
create view frota.v_rateio_bu_conferencia with (security_invoker = true) as
  select mes_competencia, hub_id, round(sum(percentual) * 100, 2) as soma_pct,
         abs(sum(percentual) - 1) <= 0.001 as fecha_100
    from frota.financeiro_rateio_bu
   group by mes_competencia, hub_id;
revoke all on frota.v_rateio_bu_conferencia from anon;
grant select on frota.v_rateio_bu_conferencia to authenticated;

-- Matriz por BU: pega a matriz por hub (financeiro_fechamento) e divide cada linha pelos % do hub
-- (ou da linha "Total" quando o hub não está na planilha). Mês sem rateio → tudo em "(sem rateio)".
create or replace function frota.financeiro_fechamento_bu(p_mes date)
returns table (bu text, aluguel numeric, combustivel numeric, pedagio_estacionamento numeric,
               lavagem numeric, garagem numeric, outras numeric, total numeric)
language plpgsql stable security definer set search_path = frota, public as $$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not frota.posso_ver('financeiro') then raise exception 'Sem permissão para ver o Financeiro'; end if;
  return query
  with f as (select * from frota.financeiro_fechamento(v_mes)),
  r as (
    select f.*, coalesce(rh.bu_nome, rt.bu_nome, '(sem rateio)') as bu_x,
           coalesce(rh.percentual, rt.percentual, 1) as pct
      from f
      left join frota.financeiro_rateio_bu rh on rh.mes_competencia = v_mes and rh.hub_id = f.hub_id
      left join frota.financeiro_rateio_bu rt on rt.mes_competencia = v_mes and rt.hub_id is null
                                              and not exists (select 1 from frota.financeiro_rateio_bu x
                                                               where x.mes_competencia = v_mes and x.hub_id = f.hub_id)
  )
  select bu_x, round(sum(r.aluguel * pct), 2), round(sum(r.combustivel * pct), 2),
         round(sum(r.pedagio_estacionamento * pct), 2), round(sum(r.lavagem * pct), 2),
         round(sum(r.garagem * pct), 2), round(sum(r.outras * pct), 2), round(sum(r.total * pct), 2)
    from r group by bu_x order by bu_x;
end $$;
revoke all on function frota.financeiro_fechamento_bu(date) from public, anon;
grant execute on function frota.financeiro_fechamento_bu(date) to authenticated;
