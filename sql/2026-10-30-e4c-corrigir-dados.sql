-- =============================================================================
-- Descontos em folha — Etapa 4c (30/10/2026): "Corrigir dados" sem trocar de fase.
-- Decisão do Jefferson: durante as fases em andamento a Frota pode ajustar motorista, valor, parcelas e líder;
-- cada alteração fica na linha do tempo (imutável) COM justificativa.
--
-- Mudanças no gatilho descontos_folha_regras (o resto é idêntico ao da Etapa 1):
--   1. Sem troca de fase, CORRIGIR (mudar um valor que já existia) exige a justificativa em observacao_fase
--      (pelo menos 5 letras): motorista já definido, líder já preenchido, valor, valor bruto já preenchido,
--      valor com desconto e parcelas. Definir pela primeira vez (motorista ou líder vazio) não exige.
--      Mesma regra de Regras.correcaoDesconto no regras.js.
--   2. A troca de líder e de valor bruto/com desconto também entra no histórico.
--   3. O histórico guarda o "antes" de cada correção (valor_anterior, parcelas_anterior, lider_anterior,
--      valor_bruto/valor_com_desconto novos) para a linha do tempo mostrar "de → para".
-- =============================================================================
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
  lider_antes text; lider_depois text;
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
    lider_antes := nullif(trim(old.lider_nome), '');
    lider_depois := nullif(trim(new.lider_nome), '');
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
  elsif tg_op = 'UPDATE' then
    -- Corrigir dados (4c): mudar um valor que já existia exige justificativa; definir pela 1ª vez não exige
    if not frota.texto_ok(obs) and (
         (old.motorista_id is not null and new.motorista_id is distinct from old.motorista_id)
         or (lider_antes is not null and lider_depois is distinct from lider_antes)
         or new.valor is distinct from old.valor
         or (old.valor_bruto is not null and new.valor_bruto is distinct from old.valor_bruto)
         or new.valor_com_desconto is distinct from old.valor_com_desconto
         or new.parcelas is distinct from old.parcelas) then
      raise exception 'Corrigir dados exige a justificativa (pelo menos 5 letras).';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if new.fase = 'custo_beep' and not frota.texto_ok(new.motivo_custo_beep) then raise exception 'Custo Beep exige o motivo.'; end if;
    registrar := true;
  elsif new.motorista_id is distinct from old.motorista_id or new.valor is distinct from old.valor
        or new.parcelas is distinct from old.parcelas or obs is not null
        or lider_depois is distinct from lider_antes
        or new.valor_bruto is distinct from old.valor_bruto or new.valor_com_desconto is distinct from old.valor_com_desconto then
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
    if tg_op = 'UPDATE' then
      det := det || jsonb_strip_nulls(jsonb_build_object(
        'valor_anterior', case when new.valor is distinct from old.valor then old.valor end,
        'parcelas_anterior', case when new.parcelas is distinct from old.parcelas then old.parcelas end,
        'valor_bruto', case when new.valor_bruto is distinct from old.valor_bruto then new.valor_bruto end,
        'valor_bruto_anterior', case when new.valor_bruto is distinct from old.valor_bruto then old.valor_bruto end,
        'valor_com_desconto', case when new.valor_com_desconto is distinct from old.valor_com_desconto then new.valor_com_desconto end,
        'valor_com_desconto_anterior', case when new.valor_com_desconto is distinct from old.valor_com_desconto then old.valor_com_desconto end,
        'lider_nome', case when lider_depois is distinct from lider_antes then lider_depois end,
        'lider_anterior', case when lider_depois is distinct from lider_antes then lider_antes end,
        'lider_trocado', case when lider_depois is distinct from lider_antes then true end,
        'valor_com_desconto_trocado', case when new.valor_com_desconto is distinct from old.valor_com_desconto then true end));
    end if;
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
revoke execute on function frota.tg_descontos_folha_regras() from public, anon, authenticated;
