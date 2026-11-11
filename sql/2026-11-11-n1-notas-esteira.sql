-- Notas Fiscais N1 (11/11/2026, aprovado pelo Jefferson): esteira de status da nota, histórico imutável e recorrência.
-- Esteira (etapa): pendente_envio → enviado (Pipe + data de envio ao Financeiro) → pago (data de pagamento, quando o Financeiro
-- confirma a liquidação) | recusado (motivo; a Frota corrige e reenvia). Reabrir (com motivo): pago → enviado, enviado/recusado → pendente.
-- Quem fez vem SEMPRE do login (auth.uid) — gravado pelo gatilho, nunca pelo navegador; o nome é o do perfil (ou o e-mail).
-- Notas antigas: `responsavel_planilha` guarda o nome da coluna "Responsável" da planilha (só histórico, vem na carga N2).
-- As notas que já existem ficam em "pendente_envio" até a carga N2, que traz a etapa real da planilha.

alter table frota.notas_fiscais
  add column if not exists etapa text not null default 'pendente_envio'
    check (etapa in ('pendente_envio', 'enviado', 'pago', 'recusado')),
  add column if not exists data_envio_financeiro date,
  add column if not exists criado_por uuid,
  add column if not exists enviado_por uuid,
  add column if not exists pago_por uuid,
  add column if not exists motivo_recusa text,
  add column if not exists responsavel_planilha text,
  add column if not exists etapa_atualizada_em timestamptz,
  add column if not exists observacao_etapa text;   -- só de passagem: vai para o histórico e é limpa

create table if not exists frota.notas_fiscais_historico (
  id            uuid primary key default gen_random_uuid(),
  nota_id       uuid not null references frota.notas_fiscais(id) on delete cascade,
  etapa_de      text,
  etapa_para    text not null,
  observacao    text,
  pipefy_card_id text,
  data_ref      date,                       -- data de envio ou de pagamento informada no passo
  origem        text not null default 'tela' check (origem in ('tela', 'importacao', 'sistema')),
  feito_por     uuid default auth.uid(),
  feito_por_nome text,
  feito_em      timestamptz not null default clock_timestamp()
);
create index if not exists notas_fiscais_historico_nota on frota.notas_fiscais_historico (nota_id, feito_em);

alter table frota.notas_fiscais_historico enable row level security;
revoke all on frota.notas_fiscais_historico from anon, authenticated;
grant select on frota.notas_fiscais_historico to authenticated;   -- grava só o gatilho; ninguém altera nem apaga
grant all on frota.notas_fiscais_historico to service_role;
create policy nf_historico_ler on frota.notas_fiscais_historico for select to authenticated using (frota.posso_ver('financeiro'));

create or replace function frota.tg_nf_historico_imutavel() returns trigger language plpgsql as $$
begin
  -- só sai junto com a própria nota (on delete cascade)
  if tg_op = 'DELETE' and not exists (select 1 from frota.notas_fiscais n where n.id = old.nota_id) then return old; end if;
  raise exception 'Histórico da nota fiscal não pode ser alterado nem apagado.';
end $$;
create trigger nf_historico_imutavel before update or delete on frota.notas_fiscais_historico
  for each row execute function frota.tg_nf_historico_imutavel();

-- nome de quem está logado: perfil, senão e-mail do login
create or replace function frota.nome_usuario_atual() returns text language sql stable security definer set search_path = frota, public as $$
  select coalesce((select p.nome from frota.usuarios_perfil p where p.user_id = auth.uid()),
                  (select u.email::text from auth.users u where u.id = auth.uid()))
$$;
revoke all on function frota.nome_usuario_atual() from public, anon;
grant execute on function frota.nome_usuario_atual() to authenticated;

-- regras da esteira (vale para as funções, para a tela e para a importação)
create or replace function frota.tg_notas_fiscais_esteira() returns trigger language plpgsql security definer set search_path = frota, public as $$
declare v_obs text;
begin
  if tg_op = 'INSERT' then
    new.criado_por := coalesce(auth.uid(), new.criado_por);
    new.etapa_atualizada_em := now();
  elsif new.etapa is distinct from old.etapa then
    new.etapa_atualizada_em := now();
  end if;
  -- campo obrigatório de cada etapa
  if new.etapa = 'enviado' and (new.pipefy_card_id is null or new.pipefy_card_id !~ '^\d+$' or new.data_envio_financeiro is null) then
    raise exception 'Para "Enviado" é preciso o número do Pipe (só números) e a data de envio ao Financeiro.';
  end if;
  if new.etapa = 'pago' and new.data_pagamento is null then
    raise exception 'Para "Pago" é preciso a data de pagamento.';
  end if;
  if new.etapa = 'recusado' and not frota.texto_ok(new.motivo_recusa) then
    raise exception 'Para "Recusado" é preciso o motivo da recusa (pelo menos 5 letras).';
  end if;
  if tg_op = 'UPDATE' and new.etapa is distinct from old.etapa then
    if new.etapa = 'enviado' and old.etapa <> 'pago' then new.enviado_por := coalesce(auth.uid(), new.enviado_por); end if;
    if new.etapa = 'pago' then new.pago_por := coalesce(auth.uid(), new.pago_por); end if;
    if old.etapa = 'recusado' and new.etapa <> 'recusado' then new.motivo_recusa := null; end if;
    if old.etapa = 'pago' and new.etapa <> 'pago' then new.data_pagamento := null; new.pago_por := null; end if;
    v_obs := coalesce(new.observacao_etapa, case when new.etapa = 'recusado' then new.motivo_recusa end);
    insert into frota.notas_fiscais_historico (nota_id, etapa_de, etapa_para, observacao, pipefy_card_id, data_ref, origem, feito_por, feito_por_nome)
    values (new.id, old.etapa, new.etapa, v_obs, new.pipefy_card_id,
            case new.etapa when 'enviado' then new.data_envio_financeiro when 'pago' then new.data_pagamento end,
            case when auth.uid() is null then 'sistema' when new.importado_em is distinct from old.importado_em then 'importacao' else 'tela' end,
            auth.uid(), frota.nome_usuario_atual());
  end if;
  new.observacao_etapa := null;
  return new;
end $$;
revoke all on function frota.tg_notas_fiscais_esteira() from public, anon, authenticated;
create trigger notas_fiscais_esteira before insert or update on frota.notas_fiscais
  for each row execute function frota.tg_notas_fiscais_esteira();

create or replace function frota.tg_notas_fiscais_criada() returns trigger language plpgsql security definer set search_path = frota, public as $$
begin
  insert into frota.notas_fiscais_historico (nota_id, etapa_de, etapa_para, observacao, pipefy_card_id, data_ref, origem, feito_por, feito_por_nome)
  values (new.id, null, new.etapa, 'Nota cadastrada', new.pipefy_card_id,
          case new.etapa when 'enviado' then new.data_envio_financeiro when 'pago' then new.data_pagamento end,
          case when auth.uid() is null then 'sistema' when new.origem_carga = 'planilha' then 'importacao' else 'tela' end,
          auth.uid(), coalesce(frota.nome_usuario_atual(), new.responsavel_planilha));
  return null;
end $$;
revoke all on function frota.tg_notas_fiscais_criada() from public, anon, authenticated;
create trigger notas_fiscais_criada after insert on frota.notas_fiscais
  for each row execute function frota.tg_notas_fiscais_criada();

-- Ações da esteira (security invoker: valem as permissões da nota — admin e operador do Financeiro)
create or replace function frota.nf_registrar_envio(p_id uuid, p_pipe text, p_data date default null)
returns text language plpgsql set search_path = frota, public as $$
declare v_etapa text; v_pipe text := btrim(coalesce(p_pipe, ''));
begin
  select etapa into v_etapa from notas_fiscais where id = p_id;
  if v_etapa is null then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  if v_etapa = 'pago' then raise exception 'Nota já paga: para mudar, reabra primeiro.'; end if;
  if v_pipe !~ '^\d+$' then raise exception 'Informe o número do Pipe (só números).'; end if;
  update notas_fiscais set pipefy_card_id = v_pipe, etapa = 'enviado',
         data_envio_financeiro = coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date)
   where id = p_id;
  if not found then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  return 'enviado';
exception when unique_violation then raise exception 'Esse número do Pipe já está em outra nota.';
end $$;

create or replace function frota.nf_recusar(p_id uuid, p_motivo text)
returns text language plpgsql set search_path = frota, public as $$
declare v_etapa text;
begin
  select etapa into v_etapa from notas_fiscais where id = p_id;
  if v_etapa is null then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  if v_etapa <> 'enviado' then raise exception 'Só nota enviada ao Financeiro pode ser recusada.'; end if;
  if not texto_ok(p_motivo) then raise exception 'Informe o motivo da recusa (pelo menos 5 letras).'; end if;
  update notas_fiscais set etapa = 'recusado', motivo_recusa = btrim(p_motivo) where id = p_id;
  if not found then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  return 'recusado';
end $$;

create or replace function frota.nf_marcar_paga(p_id uuid, p_data date)
returns text language plpgsql set search_path = frota, public as $$
declare v_etapa text;
begin
  select etapa into v_etapa from notas_fiscais where id = p_id;
  if v_etapa is null then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  if v_etapa <> 'enviado' then raise exception 'Só nota enviada ao Financeiro pode ser marcada como paga.'; end if;
  if p_data is null then raise exception 'Informe a data de pagamento.'; end if;
  if p_data > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data de pagamento no futuro.'; end if;
  update notas_fiscais set etapa = 'pago', data_pagamento = p_data where id = p_id;
  if not found then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  return 'pago';
end $$;

create or replace function frota.nf_reabrir(p_id uuid, p_motivo text)
returns text language plpgsql set search_path = frota, public as $$
declare v_etapa text; v_nova text;
begin
  select etapa into v_etapa from notas_fiscais where id = p_id;
  if v_etapa is null then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  if not texto_ok(p_motivo) then raise exception 'Informe o motivo para reabrir (pelo menos 5 letras).'; end if;
  v_nova := case v_etapa when 'pago' then 'enviado' when 'pendente_envio' then null else 'pendente_envio' end;
  if v_nova is null then raise exception 'A nota já está pendente de envio.'; end if;
  update notas_fiscais set etapa = v_nova, observacao_etapa = 'Reaberta: ' || btrim(p_motivo) where id = p_id;
  if not found then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  return v_nova;
end $$;

revoke all on function frota.nf_registrar_envio(uuid, text, date), frota.nf_recusar(uuid, text),
                       frota.nf_marcar_paga(uuid, date), frota.nf_reabrir(uuid, text) from public, anon;
grant execute on function frota.nf_registrar_envio(uuid, text, date), frota.nf_recusar(uuid, text),
                          frota.nf_marcar_paga(uuid, date), frota.nf_reabrir(uuid, text) to authenticated;

-- Recorrência: fornecedor + hub + conta com nota em pelo menos 3 dos 6 meses antes de p_mes (notas não canceladas).
-- dia_habitual = média do dia da emissão nesses meses. situacao: emitiu (já tem nota no mês) | no_prazo (mês corrente e hoje
-- ≤ dia habitual + 3) | atrasada (passou do dia habitual + 3, ou mês já passado sem nota).
create or replace function frota.nf_recorrencia(p_mes date)
returns table (fornecedor_id uuid, fornecedor text, hub_id uuid, hub text, categoria_id uuid, conta text,
               meses_com_nota int, dia_habitual int, valor_medio numeric, ultima_competencia date,
               emitiu_no_mes boolean, situacao text)
language sql stable set search_path = frota, public as $$
  with m as (select date_trunc('month', p_mes)::date as mes,
                    (now() at time zone 'America/Sao_Paulo')::date as hoje),
  hist as (
    select n.fornecedor_id, n.hub_id, n.categoria_id,
           count(distinct date_trunc('month', n.mes_referencia)) as meses,
           round(avg(extract(day from n.data_emissao)))::int as dia,
           round(avg(n.valor), 2) as valor_medio,
           max(date_trunc('month', n.mes_referencia))::date as ultima
      from notas_fiscais n, m
     where n.mes_referencia >= (m.mes - interval '6 months')::date and n.mes_referencia < m.mes
       and coalesce(n.aprovacao, 'aprovado') = 'aprovado'
     group by 1, 2, 3
    having count(distinct date_trunc('month', n.mes_referencia)) >= 3
  )
  select h.fornecedor_id, f.nome, h.hub_id, hb.nome, h.categoria_id, c.nome, h.meses::int, h.dia, h.valor_medio, h.ultima,
         e.existe,
         case when e.existe then 'emitiu'
              when m.mes = date_trunc('month', m.hoje)::date and extract(day from m.hoje) <= coalesce(h.dia, 28) + 3 then 'no_prazo'
              when m.mes > date_trunc('month', m.hoje)::date then 'no_prazo'
              else 'atrasada' end
    from hist h cross join m
    left join fornecedores f on f.id = h.fornecedor_id
    left join hubs hb on hb.id = h.hub_id
    left join categorias_custo c on c.id = h.categoria_id
    cross join lateral (select exists (select 1 from notas_fiscais x
                          where x.fornecedor_id = h.fornecedor_id and x.hub_id is not distinct from h.hub_id
                            and x.categoria_id is not distinct from h.categoria_id
                            and date_trunc('month', x.mes_referencia) = m.mes
                            and coalesce(x.aprovacao, 'aprovado') = 'aprovado') as existe) e
   order by (case when e.existe then 2 else 1 end), f.nome, hb.nome
$$;
revoke all on function frota.nf_recorrencia(date) from public, anon;
grant execute on function frota.nf_recorrencia(date) to authenticated;
