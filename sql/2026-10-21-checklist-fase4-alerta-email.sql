-- Checklist de Veículo — Fase 4: e-mail de alerta de anomalia nova.
-- Fluxo: checklist vira 'enviado' com qtd_anomalias_novas > 0 → gatilho chama (pg_net) a
-- Edge Function `alerta-checklist` → 1 e-mail por checklist para frota@beepsaude.com.br,
-- saindo da conta definida em SMTP_USER (hoje a do Jefferson; SMTP Google Workspace, porta 465).
-- Aplicada em 2 partes: estrutura (chave, colunas, funções) e, depois do e-mail de teste, gatilho + cron.
-- Rede de segurança: cron a cada 15 min reenvia o que falhou (até 5 tentativas, últimas 48h).
-- Anomalia crítica só alerta por e-mail: não muda status do veículo nem abre OS (decisão do Jefferson).

-- chave interna gatilho/cron -> Edge Function (fica no Vault; nunca sai do Supabase)
select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
                           'automation_secret_checklist',
                           'Chave interna: gatilho/cron -> Edge Function alerta-checklist');

create or replace function frota.verificar_chave_checklist(chave text) returns boolean
language sql stable security definer set search_path = frota as $$
  select exists (select 1 from vault.decrypted_secrets
                  where name = 'automation_secret_checklist' and decrypted_secret = chave);
$$;
revoke all on function frota.verificar_chave_checklist(text) from public, anon, authenticated;
grant execute on function frota.verificar_chave_checklist(text) to service_role;

-- controle de envio no próprio checklist
alter table frota.checklists
  add column alerta_status       text check (alerta_status in ('enviado','ignorado','erro')),
  add column alerta_enviado_em   timestamptz,
  add column alerta_erro         text,
  add column alerta_tentativas   int not null default 0,
  add column alerta_reservado_em timestamptz;

-- "reserva" o checklist para envio (evita e-mail duplicado se gatilho e cron coincidirem)
create or replace function frota.reservar_alerta_checklist(p_id uuid) returns boolean
language plpgsql security invoker set search_path = frota as $$
begin
  update checklists
     set alerta_reservado_em = now(), alerta_tentativas = alerta_tentativas + 1
   where id = p_id and status = 'enviado' and qtd_anomalias_novas > 0
     and coalesce(alerta_status, 'erro') = 'erro' and alerta_tentativas < 5
     and (alerta_reservado_em is null or alerta_reservado_em < now() - interval '10 minutes');
  return found;
end $$;

create or replace function frota.listar_alertas_pendentes() returns setof uuid
language sql stable security invoker set search_path = frota as $$
  select id from checklists
   where status = 'enviado' and qtd_anomalias_novas > 0
     and coalesce(alerta_status, 'erro') = 'erro' and alerta_tentativas < 5
     and enviado_em > now() - interval '48 hours' and enviado_em < now() - interval '5 minutes'
     and (alerta_reservado_em is null or alerta_reservado_em < now() - interval '10 minutes')
   order by enviado_em;
$$;
revoke all on function frota.reservar_alerta_checklist(uuid), frota.listar_alertas_pendentes() from public, anon, authenticated;
grant execute on function frota.reservar_alerta_checklist(uuid), frota.listar_alertas_pendentes() to service_role;

-- gatilho: dispara a Edge Function quando o checklist é enviado com anomalia nova.
-- Falha aqui nunca pode impedir o envio do checklist (o cron reenvia depois).
create or replace function frota.tg_checklist_alerta() returns trigger
language plpgsql security definer set search_path = frota as $$
begin
  if new.status = 'enviado' and old.status is distinct from 'enviado' and new.qtd_anomalias_novas > 0 then
    begin
      perform net.http_post(
        url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
        body := jsonb_build_object('modo', 'checklist', 'checklist_id', new.id));
    exception when others then
      raise warning 'alerta-checklist não disparado para %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end $$;
create trigger checklist_alerta after update of status on frota.checklists
  for each row execute function frota.tg_checklist_alerta();

-- rede de segurança: reenvia pendentes/erros a cada 15 min
select cron.schedule('alerta-checklist-pendentes', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/alerta-checklist',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_checklist')),
    body := jsonb_build_object('modo', 'pendentes'));
$cron$);
