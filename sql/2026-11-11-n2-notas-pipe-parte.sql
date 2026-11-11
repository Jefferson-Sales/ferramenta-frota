-- Notas Fiscais N2 — banco (11/11/2026, aprovado pelo Jefferson)
-- 1) Mesmo Pipe em várias linhas (ex.: West Plaza — uma NF cobrindo garagem de 2 meses + energia): chave passa a ser
--    Pipe + parte (1, 2, 3…). A parte é calculada na leitura da planilha (maior valor = parte 1), então reimportar não duplica.
-- 2) Pagamento agendado (data futura na planilha): a nota fica "Enviado" e a data vai para data_pagamento_prevista.
-- 3) Campos da planilha que a lista nova (N3) mostra: descrição, veículo (texto livre da planilha), justificativa do atraso.
-- 4) Importação não carimba "enviado por"/"pago por" com o login de quem importou (quem fez de verdade está em
--    responsavel_planilha); o histórico continua registrando quem importou, com origem = importacao.

alter table frota.notas_fiscais
  add column if not exists pipe_parte smallint not null default 1 check (pipe_parte between 1 and 99),
  add column if not exists data_pagamento_prevista date,
  add column if not exists descricao text,
  add column if not exists veiculo_texto text,
  add column if not exists justificativa_atraso text;

alter table frota.notas_fiscais drop constraint notas_fiscais_pipe_unico;
alter table frota.notas_fiscais add constraint notas_fiscais_pipe_parte_unico unique (pipefy_card_id, pipe_parte);

create or replace function frota.tg_notas_fiscais_esteira() returns trigger language plpgsql security definer set search_path = frota, public as $$
declare v_obs text; v_import boolean;
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
    v_import := new.importado_em is distinct from old.importado_em;
    if not v_import then
      if new.etapa = 'enviado' and old.etapa <> 'pago' then new.enviado_por := coalesce(auth.uid(), new.enviado_por); end if;
      if new.etapa = 'pago' then new.pago_por := coalesce(auth.uid(), new.pago_por); end if;
    end if;
    if old.etapa = 'recusado' and new.etapa <> 'recusado' then new.motivo_recusa := null; end if;
    if old.etapa = 'pago' and new.etapa <> 'pago' then new.data_pagamento := null; new.pago_por := null; end if;
    v_obs := coalesce(new.observacao_etapa, case when new.etapa = 'recusado' then new.motivo_recusa end,
                      case when v_import then 'Carga da planilha' end);
    insert into frota.notas_fiscais_historico (nota_id, etapa_de, etapa_para, observacao, pipefy_card_id, data_ref, origem, feito_por, feito_por_nome)
    values (new.id, old.etapa, new.etapa, v_obs, new.pipefy_card_id,
            case new.etapa when 'enviado' then new.data_envio_financeiro when 'pago' then new.data_pagamento end,
            case when auth.uid() is null then 'sistema' when v_import then 'importacao' else 'tela' end,
            auth.uid(), frota.nome_usuario_atual());
  end if;
  if new.etapa = 'pago' then new.data_pagamento_prevista := null; end if;
  new.observacao_etapa := null;
  return new;
end $$;
revoke all on function frota.tg_notas_fiscais_esteira() from public, anon, authenticated;

-- registrar envio: o Pipe digitado não pode ser de outra nota (qualquer parte)
create or replace function frota.nf_registrar_envio(p_id uuid, p_pipe text, p_data date default null)
returns text language plpgsql set search_path = frota, public as $$
declare v_etapa text; v_pipe text := btrim(coalesce(p_pipe, ''));
begin
  select etapa into v_etapa from notas_fiscais where id = p_id;
  if v_etapa is null then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  if v_etapa = 'pago' then raise exception 'Nota já paga: para mudar, reabra primeiro.'; end if;
  if v_pipe !~ '^\d+$' then raise exception 'Informe o número do Pipe (só números).'; end if;
  if exists (select 1 from notas_fiscais x where x.pipefy_card_id = v_pipe and x.id <> p_id) then
    raise exception 'Esse número do Pipe já está em outra nota.';
  end if;
  update notas_fiscais set pipefy_card_id = v_pipe, pipe_parte = 1, etapa = 'enviado',
         data_envio_financeiro = coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date)
   where id = p_id;
  if not found then raise exception 'Nota não encontrada ou sem permissão.'; end if;
  return 'enviado';
exception when unique_violation then raise exception 'Esse número do Pipe já está em outra nota.';
end $$;
revoke all on function frota.nf_registrar_envio(uuid, text, date) from public, anon;
grant execute on function frota.nf_registrar_envio(uuid, text, date) to authenticated;
