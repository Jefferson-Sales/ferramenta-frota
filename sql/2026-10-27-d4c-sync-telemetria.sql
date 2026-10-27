-- =============================================================================
-- D4c — ajuste da sincronização diária da Questar (27/10/2026)
-- Código da Edge Function: supabase/functions/sync-telemetria-questar/index.ts (versão 10).
--   dia de Brasília (horários da Questar são UTC), hodômetro do fim de cada dia, paginação,
--   viagens gravadas em telemetria_viagens; diagnóstico sem localização/nome de motorista.
-- =============================================================================

-- 1) Cron das 02:00 BRT com tempo de espera de 150 s (o padrão do pg_net é 5 s).
select cron.alter_job(
  job_id := (select jobid from cron.job where jobname = 'sync-telemetria-questar-diario'),
  command := $c$
  select net.http_post(
    url := 'https://efmpzjkqiwyuumaoumof.supabase.co/functions/v1/sync-telemetria-questar',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-automation-key', (select decrypted_secret from vault.decrypted_secrets where name = 'automation_secret_questar')
    ),
    body := jsonb_build_object('mode', 'sync', 'days', 2),
    timeout_milliseconds := 150000
  ) as request_id;
  $c$);

-- 2) Cópia das linhas antes do reprocessamento (680 linhas, 35.166 km). Sem acesso pelo painel.
create table frota._backup_telemetria_diaria_2026_10_27 as
  select * from frota.telemetria_diaria where data >= '2026-10-12';
alter table frota._backup_telemetria_diaria_2026_10_27 enable row level security;
revoke all on frota._backup_telemetria_diaria_2026_10_27 from anon, authenticated;
