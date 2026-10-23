-- Sinistro: o carro parou ou continua rodando (23/10/2026, pedido do Jefferson).
-- ordens_servico.veiculo_parado: true = parou (fica indisponível), false = continua rodando (OS não mexe no status do carro),
-- null = não informado (OS antigas e tipos que não perguntam) → tratado como "parou", igual ao comportamento de antes.
-- O formulário exige a resposta quando o tipo é sinistro.

alter table frota.ordens_servico add column if not exists veiculo_parado boolean;
comment on column frota.ordens_servico.veiculo_parado is
  'Sinistro: true = carro parou (indisponível), false = continua rodando (OS não deixa indisponível), null = não informado (conta como parado).';

create or replace function frota.sync_status_veiculo_por_os()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'frota', 'public'
as $function$
declare
  v_status_atual frota.status_veiculo;
  v_tem_os_ativa boolean;
begin
  select status into v_status_atual from frota.veiculos where id = coalesce(new.veiculo_id, old.veiculo_id);
  if v_status_atual is null then
    return coalesce(new, old);
  end if;

  -- OS ativa com o carro parado → indisponível ("continua rodando" não conta)
  if new.veiculo_id is not null and new.status not in ('agendada','concluida','cancelada') and new.data_parou is not null
     and coalesce(new.veiculo_parado, true) then
    if v_status_atual = 'disponivel' then
      update frota.veiculos set status = 'indisponivel', status_desde = now() where id = new.veiculo_id;
    end if;
    return new;
  end if;

  -- só libera o carro se ESTA OS o segurava antes (update que concluiu/cancelou/agendou/passou a "continua rodando").
  -- Antes, criar uma OS agendada (e agora uma "continua rodando") liberava um carro indisponível por outro motivo.
  if tg_op = 'UPDATE' and old.veiculo_id is not null
     and old.status not in ('agendada','concluida','cancelada') and old.data_parou is not null and coalesce(old.veiculo_parado, true) then
    select exists(
      select 1 from frota.ordens_servico
      where veiculo_id = old.veiculo_id
        and id <> old.id
        and status not in ('agendada','concluida','cancelada')
        and data_parou is not null
        and coalesce(veiculo_parado, true)
    ) into v_tem_os_ativa;

    if not v_tem_os_ativa then
      update frota.veiculos set status = 'disponivel', status_desde = now() where id = old.veiculo_id and status = 'indisponivel';
    end if;
  end if;

  return coalesce(new, old);
end;
$function$;

-- passa a reagir também à troca parou ↔ continua rodando (CREATE OR REPLACE: sem DROP, que trava via MCP)
create or replace trigger trg_sync_status_veiculo_os
  after insert or update of status, data_parou, veiculo_id, veiculo_parado on frota.ordens_servico
  for each row execute function frota.sync_status_veiculo_por_os();
