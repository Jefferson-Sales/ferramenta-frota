-- Notas N4e (12/11/2026): nome de quem cadastrou a nota, gravado pelo banco (login), para a coluna Responsável da lista
-- quando a nota não veio da planilha (responsavel_planilha vazio). As notas da carga N2 ganham o nome de quem importou
-- só nas próximas inserções; as que já existem ficam com o responsável da planilha.
alter table frota.notas_fiscais add column if not exists criado_por_nome text;

create or replace function frota.tg_notas_fiscais_esteira() returns trigger language plpgsql security definer set search_path = frota, public as $$
declare v_obs text; v_import boolean;
begin
  if tg_op = 'INSERT' then
    new.criado_por := coalesce(auth.uid(), new.criado_por);
    new.criado_por_nome := coalesce(frota.nome_usuario_atual(), new.criado_por_nome);
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
