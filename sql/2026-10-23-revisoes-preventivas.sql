-- Revisões preventivas (23/10/2026) — parte 1: estrutura para importar o histórico da planilha
-- "Beep GESTÃO DE FROTA 2026 (1).xlsx", aba "Controle de Revisões", e a lista de marcos "a conferir".

-- revisoes_preventivas: cada linha = um marco de km feito (10k, 20k, … 100k)
alter table frota.revisoes_preventivas alter column data_revisao drop not null;  -- "feita, data não anotada" (ex.: planilha diz só "Campinas")
alter table frota.revisoes_preventivas add column if not exists marco_km integer
  check (marco_km is null or (marco_km between 10000 and 100000 and marco_km % 10000 = 0));
alter table frota.revisoes_preventivas add column if not exists origem text not null default 'manual'
  check (origem in ('planilha', 'os', 'manual'));
alter table frota.revisoes_preventivas add column if not exists observacao text;
create unique index if not exists revisoes_preventivas_veiculo_marco on frota.revisoes_preventivas (veiculo_id, marco_km) where marco_km is not null;
comment on column frota.revisoes_preventivas.marco_km is 'Marco do plano (10000…100000). Único por veículo.';
comment on column frota.revisoes_preventivas.origem is 'planilha = importado de "Controle de Revisões"; os = gravado ao concluir OS de preventiva; manual.';

-- Marcos que a planilha não confirma (anotação no lugar da data). Roteiro para conferir com hub/oficina
-- se a revisão foi feita e só faltou registrar. Pedido do Jefferson em 23/10/2026.
create table if not exists frota.revisoes_a_conferir (
  id uuid primary key default gen_random_uuid(),
  veiculo_id uuid not null references frota.veiculos(id),
  marco_km integer not null check (marco_km between 10000 and 100000 and marco_km % 10000 = 0),
  motivo text not null,             -- categoria: proxima_indicada | sem_registro | nao_fez | km_anotado | duplicada_divergente
  anotacao text,                    -- texto original da planilha
  status text not null default 'a_conferir' check (status in ('a_conferir', 'feita', 'nao_feita')),
  conferido_em timestamptz,
  conferido_por uuid,
  conferido_obs text,
  created_at timestamptz not null default now(),
  unique (veiculo_id, marco_km)
);
alter table frota.revisoes_a_conferir enable row level security;
-- mesmo padrão de revisoes_preventivas: quem vê Manutenções vê (só nos hubs dele); quem opera Manutenções confere
create policy visualizar_revisoes_a_conferir on frota.revisoes_a_conferir for select
  using (frota.posso_ver('manutencao') and frota.veiculo_liberado(veiculo_id));
create policy operador_confere_revisoes on frota.revisoes_a_conferir for update
  using ((frota.meu_papel() = 'admin' or frota.tenho_modulo('manutencao')) and frota.veiculo_liberado(veiculo_id))
  with check ((frota.meu_papel() = 'admin' or frota.tenho_modulo('manutencao')) and frota.veiculo_liberado(veiculo_id));
create policy admin_edita_revisoes_a_conferir on frota.revisoes_a_conferir for all
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');
grant select, update on frota.revisoes_a_conferir to authenticated;
grant all on frota.revisoes_a_conferir to service_role;
