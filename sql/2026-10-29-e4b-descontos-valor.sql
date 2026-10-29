-- =============================================================================
-- Etapa 4b — valor do desconto: bruto + com desconto (opcional) (29/10/2026)
-- Decisão do Jefferson (29/10/2026): o valor considerado é o "com desconto" quando preenchido; senão, o bruto.
-- O banco calcula frota.descontos_folha.valor a partir dos dois (mesma regra de Regras.valorConsiderado).
-- Gatilho "descontos_folha_a_valor" roda ANTES de "descontos_folha_regras" (ordem alfabética), que usa o valor
-- para sugerir as parcelas e grava o histórico.
-- =============================================================================
alter table frota.descontos_folha
  add column valor_bruto numeric(12,2) check (valor_bruto > 0),
  add column valor_com_desconto numeric(12,2) check (valor_com_desconto > 0),
  add constraint desconto_valor_com_desconto_menor check (valor_com_desconto is null or valor_bruto is null or valor_com_desconto <= valor_bruto);
comment on column frota.descontos_folha.valor is 'Valor considerado: valor_com_desconto quando preenchido, senão valor_bruto (calculado pelo banco quando um dos dois vem preenchido).';

create or replace function frota.tg_descontos_folha_valor() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  if new.valor_bruto is not null or new.valor_com_desconto is not null then
    new.valor := coalesce(new.valor_com_desconto, new.valor_bruto);
  end if;
  return new;
end $$;
revoke execute on function frota.tg_descontos_folha_valor() from public, anon, authenticated;
create trigger descontos_folha_a_valor before insert or update on frota.descontos_folha
  for each row execute function frota.tg_descontos_folha_valor();
