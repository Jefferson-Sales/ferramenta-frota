-- H1 (16/11/2026): histórico de hub dos veículos e rateio dos cartões pelo hub do dia da transação.
-- Aprovado pelo Jefferson ("SIM, eu aprovo a mudança") — comando mostrado antes de aplicar.
--
-- Como funciona:
--  * frota.veiculos_historico_hub: um período por estadia do carro num hub (inicio → fim; fim vazio = hub atual).
--    O período de implantação tem inicio vazio = "desde antes do histórico": o banco não sabe onde o carro estava
--    antes de hoje além do que a foto diária mostra (desde 21/10/2026 nenhum carro mudou de hub).
--  * gatilho em veiculos: trocou o hub_id → fecha o período aberto e abre outro (hora do servidor, quem trocou).
--  * hub_do_veiculo_na_data(veículo, quando): hub do período que contém a data; sem histórico → hub atual.
--  * gatilho em financeiro_transacoes_cartao: transação com veículo do cadastro (regra cadastro/historico_hub)
--    recebe o hub do dia da transação, calculado no banco (o navegador não decide). Regra fica
--    'historico_hub' quando o hub do dia é diferente do hub atual do carro.

create table frota.veiculos_historico_hub (
  id uuid primary key default gen_random_uuid(),
  veiculo_id uuid not null references frota.veiculos(id),
  hub_id uuid references frota.hubs(id),
  inicio timestamptz,                 -- vazio = desde antes do histórico (implantação)
  fim timestamptz,                    -- vazio = período atual
  origem text not null check (origem in ('implantacao', 'troca_de_hub', 'cadastro_novo')),
  alterado_por uuid,
  alterado_por_nome text,
  criado_em timestamptz not null default now(),
  check (fim is null or inicio is null or fim > inicio)
);
create unique index veiculos_historico_hub_um_aberto on frota.veiculos_historico_hub (veiculo_id) where fim is null;
create index veiculos_historico_hub_busca on frota.veiculos_historico_hub (veiculo_id, inicio);

alter table frota.veiculos_historico_hub enable row level security;
-- quem vê o hub do carro em algum módulo vê o histórico; ninguém grava pela tela (só os gatilhos)
create policy ver_historico_hub on frota.veiculos_historico_hub for select to authenticated
  using (frota.posso_ver('frota') or frota.posso_ver('financeiro') or frota.posso_ver('manutencao'));
grant select on frota.veiculos_historico_hub to authenticated;

-- histórico imutável: só o fechamento do período aberto (fim vazio → preenchido) é aceito
create or replace function frota.tg_historico_hub_imutavel() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  if tg_op = 'DELETE' then raise exception 'O histórico de hub não pode ser apagado.'; end if;
  if old.fim is not null or new.fim is null
     or (new.veiculo_id, new.hub_id, new.inicio, new.origem, new.alterado_por, new.criado_em)
        is distinct from (old.veiculo_id, old.hub_id, old.inicio, old.origem, old.alterado_por, old.criado_em) then
    raise exception 'O histórico de hub não pode ser alterado (só o período aberto é fechado na troca de hub).';
  end if;
  return new;
end $$;
create trigger historico_hub_imutavel before update or delete on frota.veiculos_historico_hub
  for each row execute function frota.tg_historico_hub_imutavel();

-- troca de hub no cadastro → fecha o período e abre outro
create or replace function frota.tg_veiculo_historico_hub() returns trigger
language plpgsql security definer set search_path = frota, public as $$
begin
  if tg_op = 'UPDATE' then
    if new.hub_id is not distinct from old.hub_id then return new; end if;
    update veiculos_historico_hub set fim = now() where veiculo_id = new.id and fim is null;
  end if;
  insert into veiculos_historico_hub (veiculo_id, hub_id, inicio, origem, alterado_por, alterado_por_nome)
  values (new.id, new.hub_id, now(), case when tg_op = 'INSERT' then 'cadastro_novo' else 'troca_de_hub' end,
          auth.uid(), (select nome from usuarios_perfil where user_id = auth.uid()));
  return new;
end $$;
create trigger veiculo_historico_hub after insert or update of hub_id on frota.veiculos
  for each row execute function frota.tg_veiculo_historico_hub();

-- implantação: um período aberto por veículo, com o hub atual, "desde antes do histórico"
insert into frota.veiculos_historico_hub (veiculo_id, hub_id, inicio, origem, alterado_por_nome)
select v.id, v.hub_id, null, 'implantacao', 'Implantação do histórico (16/11/2026)'
from frota.veiculos v;

-- hub do veículo numa data: período que contém a data; sem histórico → hub atual
create or replace function frota.hub_do_veiculo_na_data(p_veiculo uuid, p_quando timestamptz)
returns uuid language sql stable set search_path = frota, public as $$
  select coalesce(
    (select h.hub_id from veiculos_historico_hub h
      where h.veiculo_id = p_veiculo
        and (h.inicio is null or h.inicio <= p_quando)
        and (h.fim is null or h.fim > p_quando)
      order by h.inicio desc nulls last limit 1),
    (select v.hub_id from veiculos v where v.id = p_veiculo));
$$;
revoke all on function frota.hub_do_veiculo_na_data(uuid, timestamptz) from public, anon;
grant execute on function frota.hub_do_veiculo_na_data(uuid, timestamptz) to authenticated;

-- cartões (Ticket Log/Edenred): o banco põe o hub do dia da transação
create or replace function frota.tg_cartao_hub_na_data() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare h uuid; atual uuid;
begin
  if new.veiculo_id is null or new.data_hora is null or new.hub_regra not in ('cadastro', 'historico_hub') then
    return new;
  end if;
  h := hub_do_veiculo_na_data(new.veiculo_id, new.data_hora);
  if h is null then return new; end if;
  select hub_id into atual from veiculos where id = new.veiculo_id;
  new.hub_id := h;
  new.hub_regra := case when h is distinct from atual then 'historico_hub' else 'cadastro' end;
  return new;
end $$;
create trigger cartao_hub_na_data before insert or update of veiculo_id, data_hora, hub_id, hub_regra
  on frota.financeiro_transacoes_cartao for each row execute function frota.tg_cartao_hub_na_data();
