-- Notas Fiscais N4a (12/11/2026, pedido do Jefferson): cadastro completo do fornecedor, preparando a integração com o Pipefy.
-- 1) Em frota.fornecedores (lê quem vê Cadastro da Frota OU Financeiro): CNPJ único (só os 14 dígitos; o gatilho limpa
--    pontuação), razão social, inscrições municipal e estadual, regime tributário, endereço completo, forma de pagamento,
--    descrição do serviço e tipo de fornecimento. E-mail e telefone de contato reaproveitam contato_email / contato_telefone
--    (já existiam, vazios). Tudo opcional no banco porque os 83 fornecedores de hoje estão sem esses dados; o formulário
--    pede os obrigatórios.
-- 2) Dados bancários NÃO ficam em fornecedores (muita gente lê essa tabela; fornecedor pessoa física = dado pessoal):
--    tabela própria frota.fornecedores_dados_bancarios, que só admin e operador do Financeiro leem e gravam. Ninguém apaga.
--    Quem alterou por último e quando ficam gravados pelo gatilho.

do $$ begin
  create type frota.tipo_fornecimento as enum ('Produto', 'Serviços', 'Produtos e Serviços');
exception when duplicate_object then null; end $$;

alter table frota.fornecedores
  add column if not exists razao_social text,
  add column if not exists inscricao_municipal text,
  add column if not exists inscricao_estadual text,
  add column if not exists regime_tributario text
    check (regime_tributario in ('mei', 'simples_nacional', 'lucro_presumido', 'lucro_real', 'outro')),
  add column if not exists endereco text,
  add column if not exists forma_pagamento text
    check (forma_pagamento in ('boleto', 'transferencia', 'pix', 'cartao', 'debito_automatico')),
  add column if not exists servico_descricao text,
  add column if not exists tipo_fornecimento frota.tipo_fornecimento;

-- '' = cadastros antigos com CNPJ em branco (não foram alterados); o gatilho grava nulo daqui em diante
alter table frota.fornecedores add constraint fornecedores_cnpj_formato check (cnpj is null or cnpj = '' or cnpj ~ '^\d{14}$');
create unique index if not exists fornecedores_cnpj_unico on frota.fornecedores (cnpj) where cnpj is not null and cnpj <> '';

-- CNPJ chega com ou sem pontuação: guarda só os dígitos; vazio vira nulo. Textos vazios viram nulo.
create or replace function frota.tg_fornecedores_normaliza() returns trigger language plpgsql as $$
begin
  new.cnpj := nullif(regexp_replace(coalesce(new.cnpj, ''), '\D', '', 'g'), '');
  new.razao_social := nullif(btrim(new.razao_social), '');
  new.inscricao_municipal := nullif(btrim(new.inscricao_municipal), '');
  new.inscricao_estadual := nullif(btrim(new.inscricao_estadual), '');
  new.endereco := nullif(btrim(new.endereco), '');
  new.servico_descricao := nullif(btrim(new.servico_descricao), '');
  new.contato_email := nullif(lower(btrim(new.contato_email)), '');
  new.contato_telefone := nullif(btrim(new.contato_telefone), '');
  new.updated_at := now();
  return new;
end $$;
create trigger fornecedores_normaliza before insert or update on frota.fornecedores
  for each row execute function frota.tg_fornecedores_normaliza();

create table if not exists frota.fornecedores_dados_bancarios (
  fornecedor_id  uuid primary key references frota.fornecedores(id),
  banco          text,
  agencia        text,
  conta          text,
  atualizado_por uuid,
  atualizado_em  timestamptz not null default now()
);
alter table frota.fornecedores_dados_bancarios enable row level security;
revoke all on frota.fornecedores_dados_bancarios from anon, authenticated;
grant select, insert, update on frota.fornecedores_dados_bancarios to authenticated;
grant all on frota.fornecedores_dados_bancarios to service_role;
create policy fdb_ler on frota.fornecedores_dados_bancarios for select to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
create policy fdb_incluir on frota.fornecedores_dados_bancarios for insert to authenticated
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));
create policy fdb_alterar on frota.fornecedores_dados_bancarios for update to authenticated
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'))
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('financeiro'));

create or replace function frota.tg_fornecedores_bancarios() returns trigger language plpgsql as $$
begin
  new.banco := nullif(btrim(new.banco), '');
  new.agencia := nullif(btrim(new.agencia), '');
  new.conta := nullif(btrim(new.conta), '');
  new.atualizado_por := auth.uid();
  new.atualizado_em := now();
  return new;
end $$;
create trigger fornecedores_bancarios_quem before insert or update on frota.fornecedores_dados_bancarios
  for each row execute function frota.tg_fornecedores_bancarios();

-- funções dos gatilhos com search_path fixo (alerta de segurança do Supabase)
alter function frota.tg_fornecedores_normaliza() set search_path = frota, public;
alter function frota.tg_fornecedores_bancarios() set search_path = frota, public;
