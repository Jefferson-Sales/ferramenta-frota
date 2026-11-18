-- O1b (18/11/2026): no orçamento já ligado a uma OS, corrigir a placa para outro carro é recusado
-- (antes, só a troca da OS era conferida). Mensagem: desligue a OS antes de trocar a placa.
do $$
declare def text; ancora text := '  -- OS sugerida: a aberta mais recente do carro';
begin
  def := pg_get_functiondef('frota.tg_orcamentos_triagem()'::regprocedure);
  if position(ancora in def) = 0 then raise exception 'âncora não encontrada'; end if;
  if position('desligue a OS antes de trocar a placa' in def) > 0 then return; end if;
  def := replace(def, ancora,
    '  if new.os_id is not null and new.veiculo_id is distinct from (select o.veiculo_id from ordens_servico o where o.id = new.os_id) then' || chr(10) ||
    '    raise exception ''A OS ligada é de outro carro: desligue a OS antes de trocar a placa.'';' || chr(10) ||
    '  end if;' || chr(10) || chr(10) || ancora);
  execute def;
end $$;
