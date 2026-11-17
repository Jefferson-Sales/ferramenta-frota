-- V1 (17/11/2026): veículos pela planilha oficial "status_frota.xlsx" (aba Atualizar Painel Frota Ativa, colunas
-- Serviço, Placa, Status Operacional), aprovado pelo Jefferson ("OK para gravar a planilha exatamente como levantado:
-- 336 ativos e 67 arquivados, sem mexer nas 12 OS em aberto").
--  * arquivar = ativo false (nada é apagado). Devolvidos da planilha (63) + 4 devolvidos que não estão na planilha.
--  * finalidade = operacional | administrativo (coluna Serviço).
--  * DRE dos meses sem foto diária (antes de 21/10/2026): o aluguel era dividido pelos carros "ativos e não devolvidos"
--    do cadastro de HOJE; arquivar mudaria jan–set. A lista desses carros fica congelada em frota_base_historica
--    (354 carros em 17/11/2026) e as funções passam a usá-la — a DRE de jan–nov foi conferida igual antes e depois.

create table frota.frota_base_historica (
  veiculo_id uuid primary key references frota.veiculos(id),
  congelado_em timestamptz not null default now()
);
alter table frota.frota_base_historica enable row level security;   -- sem policy: só as funções da DRE (security definer) leem
comment on table frota.frota_base_historica is 'Carros usados no rateio do aluguel dos meses sem foto diária (antes de 21/10/2026), congelados em 17/11/2026 antes do arquivamento.';
insert into frota.frota_base_historica (veiculo_id)
select id from frota.veiculos where ativo and status::text <> 'devolvido';

do $$
declare f text; src text;
  velho text := 'v.ativo and v.status::text <> ''devolvido''';
  novo text := 'v.id in (select fb.veiculo_id from frota.frota_base_historica fb)';
begin
  foreach f in array array['frota.financeiro_dre(date)', 'frota.financeiro_fechamento(date)', 'frota.financeiro_exportar_fechamento(date)'] loop
    src := pg_get_functiondef(f::regprocedure);
    if position(velho in src) = 0 then raise exception 'Trecho do rateio antigo não encontrado em %', f; end if;
    execute replace(src, velho, novo);
  end loop;
end $$;

alter table frota.veiculos add constraint veiculos_finalidade_valida check (finalidade in ('operacional', 'administrativo'));
comment on column frota.veiculos.finalidade is 'operacional (campo) | administrativo';
comment on column frota.veiculos.ativo is 'false = arquivado (devolvido/contrato encerrado). Telas e contadores mostram só os ativos; nada é apagado.';

do $$
declare n int;
begin
  with pl(placa, finalidade, status) as (values
  ('TUP4J22','operacional','indisponivel'), ('SFK2I47','operacional','indisponivel'), ('DIC7A62','operacional','disponivel'), ('UCA9F35','operacional','indisponivel'), ('SFJ8J93','operacional','indisponivel'), ('SWS3C63','operacional','desmobilizar'),
  ('GHK0B63','operacional','desmobilizar'), ('GIB5C26','administrativo','disponivel'), ('SWI1F53','operacional','desmobilizar'), ('SEQ8E37','operacional','devolvido'), ('SEQ8E35','operacional','devolvido'), ('SEQ8E27','operacional','devolvido'),
  ('SEQ8E09','operacional','devolvido'), ('SEQ8E38','operacional','devolvido'), ('SEQ8E07','operacional','devolvido'), ('SEQ8E13','operacional','devolvido'), ('SEQ8E43','operacional','devolvido'), ('SEQ8E15','operacional','devolvido'),
  ('SEQ8E16','operacional','devolvido'), ('SEQ8E11','operacional','devolvido'), ('SEQ8E36','operacional','devolvido'), ('SEQ8E04','operacional','devolvido'), ('SEQ8E08','operacional','devolvido'), ('SEQ8E20','operacional','devolvido'),
  ('SEQ8E22','operacional','devolvido'), ('SEQ8E29','operacional','devolvido'), ('SEQ8E33','operacional','devolvido'), ('SEQ8E39','operacional','devolvido'), ('SEQ8E26','operacional','devolvido'), ('SEQ8F09','operacional','devolvido'),
  ('SEQ8E42','operacional','devolvido'), ('SEQ8E24','operacional','devolvido'), ('SEQ8E18','operacional','devolvido'), ('SEQ8E40','operacional','devolvido'), ('SEQ8E12','operacional','devolvido'), ('SEQ8E06','operacional','devolvido'),
  ('SEQ8E05','operacional','devolvido'), ('RNZ5H08','operacional','devolvido'), ('RNZ6E43','operacional','devolvido'), ('SFJ6A95','operacional','disponivel'), ('RNZ8D14','operacional','devolvido'), ('RTD0C50','operacional','devolvido'),
  ('RTD0C45','operacional','devolvido'), ('RNW5H79','operacional','devolvido'), ('RTC8F93','operacional','devolvido'), ('RTC8F98','operacional','devolvido'), ('RTD0C47','operacional','devolvido'), ('RNZ8D16','operacional','devolvido'),
  ('RTC8F77','operacional','devolvido'), ('RTD3A41','operacional','devolvido'), ('RNZ8D17','operacional','devolvido'), ('RTC8F67','operacional','devolvido'), ('RTC8F96','operacional','devolvido'), ('RTD0C46','operacional','devolvido'),
  ('RNT9F40','operacional','devolvido'), ('RNU9A57','operacional','devolvido'), ('RTA8I06','operacional','devolvido'), ('RTC8F95','operacional','devolvido'), ('RTD3A46','operacional','devolvido'), ('RTD9D97','operacional','devolvido'),
  ('RNZ8D10','operacional','devolvido'), ('RTC8F75','operacional','devolvido'), ('RTC8F85','operacional','devolvido'), ('RTC8F87','operacional','devolvido'), ('RTC8F91','operacional','devolvido'), ('RTD0C48','operacional','devolvido'),
  ('RTD0C49','operacional','devolvido'), ('RTD3A40','operacional','devolvido'), ('RTD3A43','operacional','devolvido'), ('RTD3A44','operacional','devolvido'), ('RTD3A45','operacional','devolvido'), ('RTE8E63','operacional','devolvido'),
  ('SWP7G26','operacional','devolvido'), ('SEZ3B02','operacional','desmobilizar'), ('SEZ3B03','operacional','desmobilizar'), ('SEI9G32','operacional','disponivel'), ('SEZ3B30','operacional','desmobilizar'), ('SEZ3B35','operacional','desmobilizar'),
  ('SEZ3B34','operacional','desmobilizar'), ('SEZ3B23','operacional','desmobilizar'), ('SEZ3B08','operacional','desmobilizar'), ('SEI9G38','operacional','disponivel'), ('SEI9G39','operacional','disponivel'), ('SEZ3B04','operacional','desmobilizar'),
  ('UEA9H62','operacional','disponivel'), ('UEG3H01','operacional','disponivel'), ('UDQ4D94','operacional','disponivel'), ('STM2H70','operacional','desmobilizar'), ('SSU6C02','operacional','desmobilizar'), ('SVN9A48','operacional','desmobilizar'),
  ('SEI9G36','operacional','disponivel'), ('SEJ1D98','operacional','disponivel'), ('SEJ1D97','operacional','disponivel'), ('QSU9G73','operacional','disponivel'), ('TYS6D91','operacional','disponivel'), ('TYS6D92','operacional','disponivel'),
  ('TYS5B75','operacional','disponivel'), ('UGV7H62','operacional','disponivel'), ('UFX7F21','operacional','disponivel'), ('UDO5D91','operacional','disponivel'), ('UEL5I13','operacional','disponivel'), ('TYS6E00','operacional','disponivel'),
  ('SFJ6B15','operacional','disponivel'), ('SFJ8J79','operacional','disponivel'), ('SFJ8J82','operacional','disponivel'), ('SVB8H20','operacional','desmobilizar'), ('SFJ8J91','operacional','disponivel'), ('SFJ8J94','operacional','disponivel'),
  ('SEZ3B27','operacional','desmobilizar'), ('SEZ3B28','operacional','desmobilizar'), ('TYS6D94','operacional','disponivel'), ('SEZ3B33','operacional','desmobilizar'), ('SEZ3B37','operacional','desmobilizar'), ('SEZ3B38','operacional','desmobilizar'),
  ('TYS6D97','operacional','disponivel'), ('UET2C24','operacional','disponivel'), ('UDL1G22','operacional','disponivel'), ('TYS6D90','operacional','disponivel'), ('UDD6B53','operacional','disponivel'), ('UEG8J95','operacional','disponivel'),
  ('UDJ7D74','operacional','disponivel'), ('UGH7H65','operacional','disponivel'), ('UGO4B91','operacional','disponivel'), ('UEH0J92','operacional','disponivel'), ('SFJ9A16','operacional','disponivel'), ('QSO3I67','operacional','disponivel'),
  ('QSR6F99','operacional','disponivel'), ('UDM6F61','operacional','disponivel'), ('UDZ3F90','operacional','disponivel'), ('UED1F93','operacional','disponivel'), ('UEI5A36','operacional','disponivel'), ('UEL1F08','operacional','disponivel'),
  ('UER0I45','operacional','disponivel'), ('UEV0A84','operacional','disponivel'), ('FWM6E82','operacional','disponivel'), ('TUN8J13','operacional','disponivel'), ('TUL8I93','operacional','disponivel'), ('TUJ9J76','operacional','disponivel'),
  ('SFM6H90','operacional','disponivel'), ('SEZ3B40','operacional','desmobilizar'), ('TUP4J19','operacional','disponivel'), ('TUN7D35','operacional','disponivel'), ('TUJ8E18','operacional','disponivel'), ('TUP4J24','operacional','disponivel'),
  ('TUL7D34','operacional','disponivel'), ('TUP4J23','operacional','disponivel'), ('SEZ3B43','operacional','desmobilizar'), ('TUO7E70','operacional','disponivel'), ('TUN8J11','operacional','disponivel'), ('TUN8J10','operacional','disponivel'),
  ('TUV5G05','operacional','disponivel'), ('SFA5G16','operacional','desmobilizar'), ('SSS8J32','operacional','desmobilizar'), ('TUN9C04','operacional','disponivel'), ('SSY9B63','operacional','desmobilizar'), ('TUO9D33','operacional','disponivel'),
  ('TUR4H48','operacional','disponivel'), ('STB8C52','operacional','desmobilizar'), ('TUO9A05','operacional','disponivel'), ('TUP6F14','operacional','disponivel'), ('TUJ9J77','operacional','disponivel'), ('SFA8B06','operacional','desmobilizar'),
  ('TUL8J00','operacional','disponivel'), ('TUP6F17','operacional','disponivel'), ('TUL8I97','operacional','disponivel'), ('TUL8I95','operacional','disponivel'), ('TUQ5B27','operacional','disponivel'), ('TUO9A08','operacional','disponivel'),
  ('TUL8I99','operacional','disponivel'), ('TUN8J08','operacional','disponivel'), ('TUK9A05','operacional','disponivel'), ('TUK9A01','operacional','disponivel'), ('TUO7E66','operacional','disponivel'), ('TUK7E18','operacional','disponivel'),
  ('TTA6C99','operacional','disponivel'), ('TUI9A95','operacional','disponivel'), ('TUI9B00','operacional','disponivel'), ('TUJ8E17','operacional','disponivel'), ('SFA8B07','operacional','desmobilizar'), ('SFA9H61','operacional','desmobilizar'),
  ('SFJ6A85','operacional','disponivel'), ('SFJ6A96','operacional','disponivel'), ('SFJ6B14','operacional','disponivel'), ('SFJ6B21','operacional','disponivel'), ('SSR3G00','operacional','desmobilizar'), ('SST6D43','operacional','desmobilizar'),
  ('STZ8A52','operacional','desmobilizar'), ('SUE8C94','operacional','disponivel'), ('SEZ3B14','operacional','desmobilizar'), ('SEZ3B12','operacional','desmobilizar'), ('SUP1H53','operacional','desmobilizar'), ('SUP3H33','operacional','desmobilizar'),
  ('SVO3J94','operacional','desmobilizar'), ('STA6A90','operacional','desmobilizar'), ('SUY6E73','operacional','desmobilizar'), ('SFA8B05','operacional','desmobilizar'), ('SFA8B09','operacional','desmobilizar'), ('SFB5I03','operacional','desmobilizar'),
  ('SEZ3B26','operacional','desmobilizar'), ('SEZ3B29','operacional','desmobilizar'), ('SEZ3B41','operacional','desmobilizar'), ('SEZ3B24','operacional','desmobilizar'), ('SVN6I63','operacional','desmobilizar'), ('SVY6F73','operacional','desmobilizar'),
  ('STL4I60','operacional','desmobilizar'), ('SWR8I16','operacional','desmobilizar'), ('SVW2D99','operacional','desmobilizar'), ('SVY3F09','operacional','desmobilizar'), ('STC4G43','operacional','desmobilizar'), ('SWL6C73','operacional','desmobilizar'),
  ('SVO1I30','operacional','desmobilizar'), ('STC1H00','operacional','desmobilizar'), ('GAK8B13','operacional','desmobilizar'), ('FDB3B53','operacional','desmobilizar'), ('SWQ8B17','operacional','desmobilizar'), ('STR8H83','operacional','desmobilizar'),
  ('SUD1D55','operacional','desmobilizar'), ('SVZ8F82','operacional','desmobilizar'), ('STN6G90','operacional','desmobilizar'), ('SUF1D45','operacional','disponivel'), ('SUF9G82','operacional','disponivel'), ('SUG2D35','operacional','disponivel'),
  ('STG2H43','operacional','desmobilizar'), ('SWQ6J97','operacional','indisponivel'), ('STT0G63','operacional','desmobilizar'), ('STV8A78','operacional','desmobilizar'), ('SUD8D54','operacional','desmobilizar'), ('SUH9F94','operacional','disponivel'),
  ('SUI1C14','operacional','disponivel'), ('SUO1A73','operacional','desmobilizar'), ('SUX2A51','operacional','desmobilizar'), ('SEI9G40','operacional','indisponivel'), ('SVA6D95','operacional','desmobilizar'), ('SUY5A83','operacional','desmobilizar'),
  ('SUZ1E75','operacional','desmobilizar'), ('SVC4F35','operacional','desmobilizar'), ('SFA8B08','operacional','desmobilizar'), ('SVE3G48','operacional','disponivel'), ('SVW3G33','operacional','disponivel'), ('SWB3F50','operacional','desmobilizar'),
  ('SWG6B11','operacional','desmobilizar'), ('SWG7G94','operacional','desmobilizar'), ('SWI5E22','operacional','desmobilizar'), ('SWK4C82','administrativo','disponivel'), ('SWL4H62','operacional','disponivel'), ('SWP1F16','operacional','desmobilizar'),
  ('SWR8E23','operacional','indisponivel'), ('SSZ5H30','operacional','desmobilizar'), ('STG2G83','operacional','desmobilizar'), ('STL3I44','operacional','desmobilizar'), ('SVB9E73','operacional','desmobilizar'), ('FKG1A43','operacional','desmobilizar'),
  ('GDT7I83','operacional','desmobilizar'), ('SVH6G83','operacional','desmobilizar'), ('SVS7B03','operacional','desmobilizar'), ('SVT3I13','operacional','desmobilizar'), ('SVB4D73','operacional','desmobilizar'), ('SSU7G09','operacional','desmobilizar'),
  ('STE4F43','operacional','desmobilizar'), ('SVL1H34','operacional','desmobilizar'), ('SWF7D23','operacional','desmobilizar'), ('SVJ5I91','operacional','desmobilizar'), ('SWV2E30','operacional','disponivel'), ('SWP5E66','operacional','disponivel'),
  ('SWQ5E74','operacional','disponivel'), ('SWQ0C13','operacional','disponivel'), ('SWQ0E22','operacional','disponivel'), ('SWP6I57','operacional','disponivel'), ('TTA6D02','operacional','disponivel'), ('SWP9A94','operacional','disponivel'),
  ('SWQ4H62','operacional','disponivel'), ('SWQ6J91','operacional','disponivel'), ('SWP3J46','operacional','disponivel'), ('SUH2H46','operacional','disponivel'), ('SUH2E24','operacional','disponivel'), ('SUH5E66','operacional','disponivel'),
  ('SUH4D86','operacional','disponivel'), ('SUH3F06','operacional','disponivel'), ('SUH1F06','operacional','disponivel'), ('SUE6D74','operacional','disponivel'), ('SWP3H47','operacional','disponivel'), ('SUH1A34','operacional','disponivel'),
  ('SUG9D24','operacional','disponivel'), ('SUE7J72','operacional','disponivel'), ('SUF4F17','operacional','disponivel'), ('TTA6D03','operacional','disponivel'), ('SUG2J54','operacional','disponivel'), ('SUG2E94','operacional','disponivel'),
  ('SUF9F15','operacional','disponivel'), ('SWL9I93','operacional','desmobilizar'), ('SWO4D24','operacional','indisponivel'), ('SWO4H54','operacional','indisponivel'), ('TUI9A99','operacional','disponivel'), ('TUJ8E15','operacional','disponivel'),
  ('SUG5I04','operacional','disponivel'), ('SUG3E64','operacional','disponivel'), ('SUG5G16','operacional','disponivel'), ('SUH0D73','operacional','disponivel'), ('SUG7J84','operacional','disponivel'), ('SUH0F04','operacional','disponivel'),
  ('SWQ8H93','operacional','disponivel'), ('SUH5C86','operacional','disponivel'), ('SWQ6G74','operacional','disponivel'), ('SWP0J13','operacional','disponivel'), ('TUJ8E19','operacional','disponivel'), ('SWQ6C94','operacional','disponivel'),
  ('SWP4I46','operacional','disponivel'), ('SWP4A56','operacional','disponivel'), ('SUF0C54','operacional','disponivel'), ('SFJ6A86','operacional','indisponivel'), ('TXJ6G45','administrativo','disponivel'), ('SEI9G34','operacional','disponivel'),
  ('SEJ1D96','operacional','disponivel'), ('SFJ8J86','operacional','indisponivel'), ('SEI9G35','operacional','disponivel'), ('TUK7E13','operacional','disponivel'), ('SEI9G31','operacional','disponivel'), ('TUL7D35','operacional','disponivel'),
  ('TUM7D87','operacional','disponivel'), ('SEJ1D95','operacional','disponivel'), ('SFJ6A93','operacional','disponivel'), ('SFK2I45','operacional','disponivel'), ('SFJ9A24','operacional','disponivel'), ('SFJ8J84','operacional','disponivel'),
  ('SFJ6A87','operacional','disponivel'), ('SFJ6A89','operacional','disponivel'), ('SFJ6A83','operacional','disponivel'), ('SFJ8J81','operacional','indisponivel'), ('SFJ6B22','operacional','disponivel'), ('SFJ6A82','operacional','disponivel'),
  ('SFJ8J78','operacional','disponivel'), ('SWO4I06','operacional','disponivel'), ('TUN9C06','operacional','disponivel'), ('TUO9A07','operacional','disponivel'), ('TUQ8A53','operacional','disponivel'), ('UEP8E73','operacional','disponivel'),
  ('UFA4A31','operacional','disponivel'), ('UFS2C63','operacional','disponivel'), ('UFT0G24','operacional','disponivel'), ('TUM7D88','operacional','disponivel'), ('TUO7E72','operacional','disponivel'), ('TUP4J21','operacional','disponivel'),
  ('TYS6D89','operacional','disponivel'), ('SFJ6B20','operacional','disponivel'), ('SFJ8J92','operacional','disponivel'), ('SFJ8J96','operacional','disponivel'), ('SFJ8J87','operacional','disponivel'), ('SFJ6A90','operacional','disponivel'),
  ('SFJ8J80','operacional','disponivel'), ('SFJ6B17','operacional','disponivel'), ('SFJ8J83','operacional','disponivel'), ('SFK2I51','operacional','disponivel'), ('TYS6D93','operacional','disponivel'), ('SFJ8J97','operacional','disponivel'),
  ('SFJ9A25','operacional','disponivel'), ('TYS6D95','operacional','disponivel'), ('TYS6D96','operacional','disponivel'), ('UDY5H95','operacional','indisponivel'), ('SEZ3B44','operacional','desmobilizar'), ('UCA9F25','operacional','disponivel'),
  ('TYS6D98','operacional','disponivel'), ('UCA9F27','operacional','disponivel'), ('UCA9F30','operacional','disponivel'), ('UCA9F15','operacional','disponivel'), ('UCA9F19','operacional','disponivel'), ('UCA9F32','operacional','disponivel'),
  ('UCA9F24','operacional','disponivel'), ('UCA9F26','operacional','disponivel'), ('UCA9F05','operacional','disponivel'), ('UCA9F06','operacional','disponivel'), ('UCA9F29','operacional','disponivel'), ('UCA9F07','operacional','disponivel'),
  ('UCA9F16','operacional','disponivel'), ('UCA9F28','operacional','disponivel'), ('UCA9F31','operacional','disponivel'), ('UCA9F33','operacional','disponivel'), ('UCA9F34','operacional','disponivel'), ('UCA9F36','operacional','disponivel'),
  ('UCA9F14','operacional','disponivel'), ('UCA9F08','operacional','disponivel'), ('UCA9F11','operacional','disponivel'), ('UCA9F13','operacional','disponivel'), ('UCA9F17','operacional','disponivel'), ('UCA9F20','operacional','disponivel'),
  ('UCA9F21','operacional','disponivel'), ('UCA9F22','operacional','disponivel'), ('UCA9F23','operacional','disponivel'), ('UCA9F18','operacional','disponivel'), ('GHO4F02','administrativo','disponivel'), ('GFJ3H54','administrativo','disponivel'),
  ('UED8J79','administrativo','disponivel'), ('UDG7D98','administrativo','disponivel'), ('UGA9I25','operacional','disponivel'), ('UCA9F38','operacional','disponivel'), ('UED1I80','administrativo','disponivel'), ('FWM6B22','administrativo','disponivel'),
  ('GBC9I46','administrativo','disponivel'), ('UDB9A48','administrativo','disponivel'), ('UDS5J44','administrativo','disponivel')
  )
  update frota.veiculos v
     set finalidade = pl.finalidade,
         status = pl.status::frota.status_veiculo,
         status_desde = case when v.status::text <> pl.status then now() else v.status_desde end,
         ativo = (pl.status <> 'devolvido')
    from pl where v.placa = pl.placa;
  get diagnostics n = row_count;
  if n <> 399 then raise exception 'Esperava 399 placas da planilha, atualizei %', n; end if;

  update frota.veiculos set ativo = false
   where placa in ('SWP0F57', 'SWV1H13', 'TCT2D33', 'TYT4D25') and status::text = 'devolvido';
  get diagnostics n = row_count;
  if n <> 4 then raise exception 'Esperava 4 devolvidos fora da planilha, achei %', n; end if;

  select count(*) into n from frota.veiculos where not ativo;
  if n <> 67 then raise exception 'Esperava 67 arquivados, ficaram %', n; end if;
  select count(*) into n from frota.veiculos where ativo;
  if n <> 336 then raise exception 'Esperava 336 ativos, ficaram %', n; end if;
end $$;
