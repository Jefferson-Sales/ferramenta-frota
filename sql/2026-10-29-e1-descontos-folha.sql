-- =============================================================================
-- Etapa 1 — Multas e Avarias: esteira de "Descontos em folha" (29/10/2026)
-- Aprovado pelo Jefferson em 29/10/2026.
--   1. frota.ctb_infracoes (referência do CTB) + multas.ctb_codigo
--   2. frota.parcelas_sugeridas (mesma regra de Regras.parcelasSugeridas)
--   3. frota.descontos_folha (a esteira: multa ou avaria) com caminhos de fase no banco
--   4. frota.descontos_historico (imutável)
--   5. bucket privado descontos-anexos (só admin e quem opera Multas)
-- Acesso igual a Multas (sem filtro de hub). Ninguém apaga: descarta-se com "Cobrança errada".
-- =============================================================================

-- ---------------------------------------------------------------- 1. CTB
create table frota.ctb_infracoes (
  codigo                 text primary key
                         check (codigo ~ '^[0-9]{3}-[0-9]{1,2}$' or codigo ~ '^PROV-[0-9]{2}$'),  -- PROV-nn = código ainda a confirmar
  descricao              text not null check (length(trim(descricao)) between 5 and 300),
  grau                   frota.grau_infracao not null,
  pontos                 smallint generated always as (
                           case grau when 'leve' then 3 when 'media' then 4 when 'grave' then 5 when 'gravissima' then 7 end) stored,
  valor                  numeric(10,2) check (valor > 0),
  custo_beep_automatico  boolean not null default false,   -- ex.: rodízio municipal nasce como Custo Beep
  conferido              boolean not null default false,   -- só vale para sugestão (grau, Custo Beep automático) depois de conferido
  conferido_em           timestamptz,
  conferido_por          uuid,
  ativo                  boolean not null default true,
  observacao             text,
  criado_em              timestamptz not null default now()
);
comment on table frota.ctb_infracoes is 'Referência do CTB para multas. Linha só vale para sugestão depois de conferida pelo Jefferson (conferido = true). Códigos PROV-nn ainda precisam do código oficial.';

create or replace function frota.tg_ctb_conferido() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  if new.conferido and (tg_op = 'INSERT' or not old.conferido) then
    new.conferido_em := now(); new.conferido_por := auth.uid();
  elsif not new.conferido then
    new.conferido_em := null; new.conferido_por := null;
  end if;
  return new;
end $$;
create trigger ctb_conferido before insert or update on frota.ctb_infracoes
  for each row execute function frota.tg_ctb_conferido();

alter table frota.ctb_infracoes enable row level security;
create policy visualizar_ctb on frota.ctb_infracoes for select using (frota.posso_ver('multas'));
create policy admin_edita_ctb on frota.ctb_infracoes for all
  using (frota.meu_papel() = 'admin') with check (frota.meu_papel() = 'admin');
revoke all on frota.ctb_infracoes from anon, authenticated;
grant select, insert, update on frota.ctb_infracoes to authenticated;
grant all on frota.ctb_infracoes to service_role;

-- Carga inicial: enquadramentos mais frequentes nas 459 multas da frota (descrição, gravidade e valor
-- conferem com o que as notificações reais trazem). TODOS a conferir. Códigos só para os de velocidade;
-- os demais ficam PROV-nn até virem do Pipefy / auto de infração.
insert into frota.ctb_infracoes (codigo, descricao, grau, valor, custo_beep_automatico) values
  ('745-50',  'Transitar em velocidade superior à máxima permitida em até 20%',                   'media',      130.16, false),
  ('746-30',  'Transitar em velocidade superior à máxima permitida em mais de 20% até 50%',       'grave',      195.23, false),
  ('747-10',  'Transitar em velocidade superior à máxima permitida em mais de 50%',               'gravissima', 880.41, false),
  ('PROV-01', 'Avançar o sinal vermelho do semáforo',                                              'gravissima', 293.47, false),
  ('PROV-02', 'Dirigir o veículo segurando ou manuseando telefone celular',                        'gravissima', 293.47, false),
  ('PROV-03', 'Rodízio municipal (transitar em local/horário não permitido pela regulamentação)', 'media',      130.16, true),
  ('PROV-04', 'Transitar na faixa ou via exclusiva do transporte público coletivo',                'gravissima', 293.47, false),
  ('PROV-05', 'Transitar em marcha à ré em desacordo',                                             'media',      130.16, false),
  ('PROV-06', 'Estacionar em local/horário proibido pela sinalização',                             'media',      130.16, false),
  ('PROV-07', 'Estacionar em desacordo com a regulamentação (estacionamento rotativo)',            'grave',      195.23, false),
  ('PROV-08', 'Estacionar no passeio',                                                             'grave',      195.23, false),
  ('PROV-09', 'Executar conversão à esquerda em local proibido pela sinalização',                  'grave',      195.23, false),
  ('PROV-10', 'Deixar de conservar o veículo na faixa a ele destinada',                            'media',      130.16, false),
  ('PROV-11', 'Evadir-se da cobrança pelo uso de rodovias e vias urbanas (pedágio)',               'grave',      195.23, false),
  ('PROV-12', 'Deixar o passageiro de usar o cinto de segurança',                                  'grave',      195.23, false),
  ('PROV-13', 'Estacionar ao lado de outro veículo em fila dupla',                                 'grave',      195.23, false);

alter table frota.multas add column ctb_codigo text references frota.ctb_infracoes(codigo) on update cascade;

-- ---------------------------------------------------------------- 2. parcelas sugeridas (= Regras.parcelasSugeridas)
create or replace function frota.parcelas_sugeridas(p_tipo text, p_grau frota.grau_infracao, p_valor numeric)
returns smallint language sql immutable set search_path = frota, public as $$
  select (case
    when p_tipo = 'multa' then case p_grau when 'leve' then 1 when 'media' then 3 when 'grave' then 6 when 'gravissima' then 6 end
    when p_tipo = 'avaria' then case
      when p_valor is null or p_valor <= 0 then null
      when round(p_valor, 2) <= 300 then 1
      when round(p_valor, 2) <= 600 then 3
      else 6 end
  end)::smallint
$$;

-- ---------------------------------------------------------------- 3. esteira
create type frota.tipo_desconto as enum ('multa', 'avaria');
create type frota.fase_desconto as enum (
  'enviado_lider', 'avaliacao_frota', 'conferencia_frota', 'analise_rh', 'encaminhado_dp', 'rejeitada_dp',
  'confirmado_dp', 'custo_beep', 'cobranca_errada');   -- as 3 últimas são finais
create type frota.resposta_motorista as enum ('sim', 'nao', 'desligado');

create table frota.descontos_folha (
  id                     uuid primary key default gen_random_uuid(),
  tipo                   frota.tipo_desconto not null,
  multa_id               uuid unique references frota.multas(id),
  os_id                  uuid references frota.ordens_servico(id),
  anomalia_id            uuid references frota.checklist_anomalias(id),
  veiculo_id             uuid not null references frota.veiculos(id),
  hub_id                 uuid references frota.hubs(id),            -- hub NO MOMENTO da ocorrência (guardado)
  ocorrida_em            timestamptz,
  ctb_codigo             text references frota.ctb_infracoes(codigo) on update cascade,
  grau                   frota.grau_infracao,
  descricao              text check (length(descricao) <= 2000),
  motorista_id           uuid references frota.motoristas(id),
  motorista_sugerido_id  uuid references frota.motoristas(id),
  origem_sugestao        text check (origem_sugestao in ('checklist', 'telemetria', 'manual', 'importacao')),
  lider_nome             text check (length(lider_nome) <= 120),
  valor                  numeric(12,2) not null check (valor > 0),
  parcelas_sugeridas     smallint,
  parcelas               smallint not null check (parcelas between 1 and 6),
  fase                   frota.fase_desconto not null default 'enviado_lider',
  fase_desde             timestamptz not null default now(),
  motorista_concorda     frota.resposta_motorista,
  contestacao_motivo     text check (length(contestacao_motivo) <= 2000),
  contestacao_valida     boolean,
  retencao_rescisoria    boolean,
  motivo_custo_beep      text check (length(motivo_custo_beep) <= 500),
  motivo_rejeicao_dp     text check (length(motivo_rejeicao_dp) <= 500),
  motivo_cobranca_errada text check (length(motivo_cobranca_errada) <= 500),
  observacao_fase        text check (length(observacao_fase) <= 2000),  -- só de passagem: vai para o histórico e é limpa
  resultado              text generated always as (case
                           when fase = 'confirmado_dp' then 'repasse_motorista'
                           when fase = 'custo_beep' then 'custo_beep'
                           when fase = 'cobranca_errada' then 'sem_custo'
                           else 'em_andamento' end) stored,
  pipefy_card_id         text unique,
  criado_por             uuid default auth.uid(),
  criado_em              timestamptz not null default now(),
  atualizado_em          timestamptz not null default now(),
  constraint desconto_multa_campos check (tipo <> 'multa' or (os_id is null and anomalia_id is null)),
  constraint desconto_avaria_campos check (tipo <> 'avaria' or (multa_id is null and ctb_codigo is null and grau is null)),
  constraint desconto_multa_vinculo check (tipo <> 'multa' or multa_id is not null or pipefy_card_id is not null)
);
create index descontos_folha_fase on frota.descontos_folha (fase);
create index descontos_folha_veiculo on frota.descontos_folha (veiculo_id);
create index descontos_folha_motorista on frota.descontos_folha (motorista_id);
create index descontos_folha_os on frota.descontos_folha (os_id);
comment on table frota.descontos_folha is 'Esteira de descontos em folha (multas e avarias), substitui o pipe do Pipefy. Trocas de fase validadas pelo gatilho descontos_folha_regras; histórico em descontos_historico.';
comment on column frota.descontos_folha.observacao_fase is 'Observação da troca de fase (ex.: motivo de devolver ao líder). Gravada no histórico e limpa na hora.';

create table frota.descontos_historico (
  id              uuid primary key default gen_random_uuid(),
  desconto_id     uuid not null references frota.descontos_folha(id) deferrable initially deferred,
  fase_anterior   frota.fase_desconto,
  fase_nova       frota.fase_desconto not null,
  observacao      text,
  detalhes        jsonb,
  origem          text not null default 'painel' check (origem in ('painel', 'automatico', 'importacao', 'reabertura')),
  mudou_em        timestamptz not null default clock_timestamp(),  -- hora exata de cada passo
  mudou_por       uuid,
  mudou_por_nome  text
);
create index descontos_historico_desconto on frota.descontos_historico (desconto_id, mudou_em);
comment on table frota.descontos_historico is 'Histórico imutável da esteira de descontos (cada troca de fase e cada mudança de motorista, valor ou parcelas).';

create or replace function frota.tg_descontos_historico_imutavel() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  raise exception 'Registro de histórico não pode ser alterado nem apagado (%).', tg_table_name;
end $$;
create trigger descontos_historico_imutavel before update or delete on frota.descontos_historico
  for each row execute function frota.tg_descontos_historico_imutavel();

create or replace function frota.tg_descontos_sem_apagar() returns trigger
language plpgsql set search_path = frota, public as $$
begin
  raise exception 'Desconto não pode ser apagado — use a fase "Cobrança errada".';
end $$;
create trigger descontos_folha_sem_apagar before delete on frota.descontos_folha
  for each row execute function frota.tg_descontos_sem_apagar();

-- texto obrigatório com pelo menos 5 letras
create or replace function frota.texto_ok(t text) returns boolean language sql immutable set search_path = frota, public as $$
  select coalesce(length(trim(t)), 0) >= 5
$$;

create or replace function frota.tg_descontos_folha_regras() returns trigger
language plpgsql security definer set search_path = frota, public as $$
declare
  quem uuid := auth.uid();
  nome text;
  admin boolean := coalesce(frota.meu_papel() = 'admin', false) or auth.uid() is null;  -- sem login = rotina do servidor
  finais frota.fase_desconto[] := array['confirmado_dp', 'custo_beep', 'cobranca_errada']::frota.fase_desconto[];
  m record; o record; an record; c record;
  de frota.fase_desconto; para frota.fase_desconto;
  origem text := 'painel';
  obs text := nullif(trim(new.observacao_fase), '');
  det jsonb;
  registrar boolean := false;
begin
  if quem is not null then select p.nome into nome from usuarios_perfil p where p.user_id = quem; end if;

  if tg_op = 'INSERT' then
    -- completa pelo vínculo
    if new.multa_id is not null then
      select * into m from multas where id = new.multa_id;
      new.veiculo_id  := coalesce(new.veiculo_id, m.veiculo_id);
      new.hub_id      := coalesce(new.hub_id, m.hub_id);
      new.ocorrida_em := coalesce(new.ocorrida_em, m.data_infracao);
      new.valor       := coalesce(new.valor, m.valor);
      new.ctb_codigo  := coalesce(new.ctb_codigo, m.ctb_codigo);
      new.grau        := coalesce(new.grau, m.grau_infracao);
      if m.id is null then raise exception 'Multa não encontrada.'; end if;
      if new.veiculo_id is distinct from m.veiculo_id then raise exception 'A multa é de outro veículo.'; end if;
    end if;
    if new.os_id is not null then
      select * into o from ordens_servico where id = new.os_id;
      new.veiculo_id := coalesce(new.veiculo_id, o.veiculo_id);
      new.valor      := coalesce(new.valor, nullif(o.valor_total, 0));
      if new.veiculo_id is distinct from o.veiculo_id then raise exception 'A OS é de outro veículo.'; end if;
    end if;
    if new.veiculo_id is null then raise exception 'Informe o veículo.'; end if;
    new.hub_id := coalesce(new.hub_id, (select v.hub_id from veiculos v where v.id = new.veiculo_id));
    new.criado_por := quem; new.criado_em := now(); new.fase_desde := now();
    if new.pipefy_card_id is not null then
      if not admin then raise exception 'Só admin importa cards do Pipefy.'; end if;
      origem := 'importacao';
    elsif new.fase <> 'enviado_lider' then
      raise exception 'Desconto novo começa em "Enviado ao líder".';
    end if;
  else
    if new.tipo is distinct from old.tipo or new.multa_id is distinct from old.multa_id
       or new.pipefy_card_id is distinct from old.pipefy_card_id or new.criado_por is distinct from old.criado_por
       or new.criado_em is distinct from old.criado_em then
      raise exception 'Tipo, multa, card do Pipefy e criação não mudam depois de criados.';
    end if;
    if old.fase = any(finais) and not admin then
      raise exception 'Desconto finalizado — só admin reabre.';
    end if;
  end if;

  -- avaria: anomalia do mesmo carro e da mesma OS
  if new.anomalia_id is not null then
    select * into an from checklist_anomalias where id = new.anomalia_id;
    if an.veiculo_id is distinct from new.veiculo_id then raise exception 'A anomalia é de outro veículo.'; end if;
    if new.os_id is not null and an.os_id is not null and an.os_id <> new.os_id then raise exception 'A anomalia está em outra OS.'; end if;
  end if;

  -- CTB: só a linha conferida completa a gravidade e o Custo Beep automático
  if new.ctb_codigo is not null then
    select * into c from ctb_infracoes where codigo = new.ctb_codigo;
    if c.conferido and c.ativo then
      new.grau := coalesce(new.grau, c.grau);
      if tg_op = 'INSERT' and c.custo_beep_automatico and new.pipefy_card_id is null then
        new.fase := 'custo_beep';
        new.motivo_custo_beep := coalesce(nullif(trim(new.motivo_custo_beep), ''), 'Custo Beep automático: ' || c.descricao);
        origem := 'automatico';
      end if;
    end if;
  end if;

  new.parcelas_sugeridas := frota.parcelas_sugeridas(new.tipo::text, new.grau, new.valor);
  new.parcelas := coalesce(new.parcelas, new.parcelas_sugeridas);
  if new.parcelas is null then raise exception 'Informe o número de parcelas (1 a 6).'; end if;

  -- caminhos de fase
  if tg_op = 'UPDATE' and new.fase is distinct from old.fase then
    de := old.fase; para := new.fase;
    if de = any(finais) then
      if para = any(finais) then raise exception 'Reabrir: escolha uma fase em andamento.'; end if;
      if not frota.texto_ok(obs) then raise exception 'Reabrir exige o motivo (observação da fase).'; end if;
      origem := 'reabertura';
    elsif para = 'cobranca_errada' then
      if not frota.texto_ok(new.motivo_cobranca_errada) then raise exception 'Cobrança errada exige o motivo.'; end if;
    elsif de = 'enviado_lider' and para = 'conferencia_frota' then
      if new.motorista_id is null or new.motorista_concorda is distinct from 'sim' then
        raise exception 'Para ir à Conferência: motorista definido e "concorda = sim".'; end if;
    elsif de = 'enviado_lider' and para = 'avaliacao_frota' then
      if new.motorista_id is null or new.motorista_concorda is distinct from 'nao' or not frota.texto_ok(new.contestacao_motivo) then
        raise exception 'Contestação exige motorista, "concorda = não" e o motivo da contestação.'; end if;
    elsif de = 'enviado_lider' and para = 'analise_rh' then
      if new.motorista_id is null or new.motorista_concorda is distinct from 'desligado' then
        raise exception 'Análise RH só para "motorista já desligado".'; end if;
    elsif de = 'avaliacao_frota' and para = 'conferencia_frota' then
      if new.contestacao_valida is distinct from false then raise exception 'Seguir para a Conferência exige contestação "não válida".'; end if;
    elsif de = 'avaliacao_frota' and para = 'custo_beep' then
      if new.contestacao_valida is distinct from true or not frota.texto_ok(new.motivo_custo_beep) then
        raise exception 'Custo Beep pela contestação exige contestação "válida" e o motivo.'; end if;
    elsif de = 'avaliacao_frota' and para = 'enviado_lider' then
      if new.contestacao_valida is distinct from true or new.motorista_id is null
         or new.motorista_id is not distinct from old.motorista_id or not frota.texto_ok(obs) then
        raise exception 'Voltar ao líder pela contestação exige contestação "válida", trocar o motorista e a observação.'; end if;
    elsif de = 'conferencia_frota' and para = 'encaminhado_dp' then
      if new.motorista_id is null then raise exception 'Enviar ao DP exige o motorista.'; end if;
    elsif de = 'conferencia_frota' and para = 'enviado_lider' then
      if not frota.texto_ok(obs) then raise exception 'Devolver ao líder exige as Observações da Frota (motivo).'; end if;
    elsif de = 'conferencia_frota' and para = 'custo_beep' then
      if not frota.texto_ok(new.motivo_custo_beep) then raise exception 'Custo Beep exige o motivo.'; end if;
    elsif de = 'analise_rh' and para = 'encaminhado_dp' then
      if new.retencao_rescisoria is distinct from true then raise exception 'Enviar ao DP exige retenção rescisória.'; end if;
    elsif de = 'analise_rh' and para = 'custo_beep' then
      if new.retencao_rescisoria is distinct from false then raise exception 'Custo Beep na Análise RH exige "sem retenção rescisória".'; end if;
      new.motivo_custo_beep := 'Motorista desligado';
    elsif de = 'encaminhado_dp' and para = 'confirmado_dp' then
      null;
    elsif de = 'encaminhado_dp' and para = 'rejeitada_dp' then
      if not frota.texto_ok(new.motivo_rejeicao_dp) then raise exception 'Rejeitada pelo DP exige o motivo.'; end if;
    elsif de = 'rejeitada_dp' and para = 'encaminhado_dp' then
      if not frota.texto_ok(obs) then raise exception 'Reenviar ao DP exige dizer o que foi corrigido.'; end if;
    elsif de = 'rejeitada_dp' and para = 'custo_beep' then
      if not frota.texto_ok(new.motivo_custo_beep) then raise exception 'Custo Beep exige o motivo.'; end if;
    else
      raise exception 'Caminho não permitido: % → %.', de, para;
    end if;
    new.fase_desde := now();
    registrar := true;
  end if;

  if tg_op = 'INSERT' then
    if new.fase = 'custo_beep' and not frota.texto_ok(new.motivo_custo_beep) then raise exception 'Custo Beep exige o motivo.'; end if;
    registrar := true;
  elsif new.motorista_id is distinct from old.motorista_id or new.valor is distinct from old.valor
        or new.parcelas is distinct from old.parcelas or obs is not null then
    registrar := true;
  end if;

  if registrar then
    det := jsonb_strip_nulls(jsonb_build_object(
      'motorista_id', new.motorista_id,
      'motorista_anterior_id', case when tg_op = 'UPDATE' and new.motorista_id is distinct from old.motorista_id then old.motorista_id end,
      'motorista_concorda', new.motorista_concorda, 'contestacao_motivo', new.contestacao_motivo,
      'contestacao_valida', new.contestacao_valida, 'retencao_rescisoria', new.retencao_rescisoria,
      'motivo_custo_beep', case when new.fase = 'custo_beep' then new.motivo_custo_beep end,
      'motivo_rejeicao_dp', case when new.fase = 'rejeitada_dp' then new.motivo_rejeicao_dp end,
      'motivo_cobranca_errada', case when new.fase = 'cobranca_errada' then new.motivo_cobranca_errada end,
      'valor', new.valor, 'parcelas', new.parcelas));
    insert into descontos_historico (desconto_id, fase_anterior, fase_nova, observacao, detalhes, origem, mudou_por, mudou_por_nome)
    values (new.id, case when tg_op = 'UPDATE' then old.fase end, new.fase, obs, det, origem, quem, nome);
  end if;

  -- voltou ao líder: nova rodada de respostas (as anteriores ficam no histórico)
  if tg_op = 'UPDATE' and new.fase = 'enviado_lider' and old.fase <> 'enviado_lider' then
    new.motorista_concorda := null; new.contestacao_motivo := null; new.contestacao_valida := null;
  end if;
  -- saiu de um final por reabertura: limpa o motivo do final
  if tg_op = 'UPDATE' and old.fase = any(finais) and new.fase <> old.fase then
    if old.fase = 'cobranca_errada' then new.motivo_cobranca_errada := null; end if;
    if old.fase = 'custo_beep' then new.motivo_custo_beep := null; end if;
  end if;

  new.observacao_fase := null;
  new.atualizado_em := now();
  return new;
end $$;
create trigger descontos_folha_regras before insert or update on frota.descontos_folha
  for each row execute function frota.tg_descontos_folha_regras();

alter table frota.descontos_folha enable row level security;
alter table frota.descontos_historico enable row level security;
create policy visualizar_descontos on frota.descontos_folha for select using (frota.posso_ver('multas'));
create policy edita_descontos_insert on frota.descontos_folha for insert
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
create policy edita_descontos_update on frota.descontos_folha for update
  using (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'))
  with check (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'));
create policy visualizar_descontos_historico on frota.descontos_historico for select using (frota.posso_ver('multas'));
revoke all on frota.descontos_folha, frota.descontos_historico from anon, authenticated;
grant select, insert, update on frota.descontos_folha to authenticated;
grant select on frota.descontos_historico to authenticated;
grant all on frota.descontos_folha, frota.descontos_historico to service_role;

-- ---------------------------------------------------------------- 5. anexos (termo assinado, documentos)
-- caminho: {desconto_id}/{arquivo}. Termo tem nome e assinatura do colaborador → só admin e quem opera Multas.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('descontos-anexos', 'descontos-anexos', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']);

create or replace function frota.desconto_existe_txt(p text) returns boolean
language sql stable security definer set search_path = frota, public as $$
  select exists (select 1 from descontos_folha d where d.id::text = p)
$$;

create policy descontos_anexos_select on storage.objects for select
  using (bucket_id = 'descontos-anexos' and (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'))
         and frota.desconto_existe_txt((storage.foldername(name))[1]));
create policy descontos_anexos_insert on storage.objects for insert
  with check (bucket_id = 'descontos-anexos' and (frota.meu_papel() = 'admin' or frota.tenho_modulo('multas'))
              and frota.desconto_existe_txt((storage.foldername(name))[1]));
create policy descontos_anexos_delete on storage.objects for delete
  using (bucket_id = 'descontos-anexos' and frota.meu_papel() = 'admin');

-- Ajustes aplicados depois (29/10/2026): hora exata no histórico já está no create acima (clock_timestamp);
-- funções sem acesso direto de fora (o gatilho roda normalmente; o Storage usa a outra com o login do usuário).
revoke execute on function frota.desconto_existe_txt(text) from public, anon;
revoke execute on function frota.tg_descontos_folha_regras() from public, anon, authenticated;
