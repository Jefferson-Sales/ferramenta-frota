-- =============================================================================
-- D4b — carga retroativa (backfill) da telemetria Questar dos carros elétricos (27/10/2026)
-- Tabela das viagens (cada viagem = uma "saída"). Preenchida só pela Edge Function
-- backfill-questar (service_role). Idempotente pela chave drive_id da Questar.
-- NÃO guarda latitude/longitude, endereço nem nome do motorista (decisão do Jefferson);
-- driver_code fica para ligar à matrícula no futuro (D2/D4).
-- =============================================================================
create table frota.telemetria_viagens (
  drive_id            bigint primary key,            -- id da viagem na Questar
  veiculo_id          uuid not null references frota.veiculos(id),
  questar_vehicle_id  text,
  driver_code         text,
  inicio              timestamptz,
  fim                 timestamptz,
  dia                 date not null,                 -- dia da viagem em Brasília (pelo fim da viagem)
  distancia_km        numeric,
  hodometro_inicio    numeric,
  hodometro_fim       numeric,
  duracao_seg         integer,
  nivel_inicio_pct    numeric,                       -- start_fuel_level_percent (nos elétricos pode ser a bateria — a confirmar)
  nivel_fim_pct       numeric,
  energy_type         text,
  fonte               text not null default 'questar_backfill',
  sincronizado_em     timestamptz not null default now()
);
create index telemetria_viagens_veiculo_dia on frota.telemetria_viagens (veiculo_id, dia);
create index telemetria_viagens_dia on frota.telemetria_viagens (dia);
comment on table frota.telemetria_viagens is 'Viagens dos elétricos vindas da Questar (get_vehicle_trips_extended). Sem localização nem nome. Escrita só por service_role.';

alter table frota.telemetria_viagens enable row level security;
create policy visualizar_telemetria_viagens on frota.telemetria_viagens for select
  using (frota.posso_ver('eletrificacao'));
revoke all on frota.telemetria_viagens from anon, authenticated;
grant select on frota.telemetria_viagens to authenticated;
grant all on frota.telemetria_viagens to service_role;
