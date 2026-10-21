-- Grupo "Equipamentos" no catálogo do checklist (aprovado pelo Jefferson em 21/10/2026).
-- Vale nos três tipos (Retirada, Devolução, Inspeção técnica) e para todos os veículos.
-- grupo_ordem 20 = aparece por último. Celular = alta (sem celular não roda a rota); demais = média.
-- Como registrar_checklist exige resposta para todo grupo do catálogo, o grupo passa a ser obrigatório na hora.
insert into frota.checklist_itens_catalogo
  (grupo, grupo_nome, grupo_ordem, codigo, descricao, tipos, severidade_padrao, subtipos, combustiveis, ordem, ativo)
values
  ('equipamentos', 'Equipamentos', 20, 'eq_celular',          'Celular',             '{retirada,devolucao,inspecao_tecnica}', 'alta',  null, null, 1, true),
  ('equipamentos', 'Equipamentos', 20, 'eq_cabo_carregador',  'Cabo de carregador',  '{retirada,devolucao,inspecao_tecnica}', 'media', null, null, 2, true),
  ('equipamentos', 'Equipamentos', 20, 'eq_carregador',       'Carregador',          '{retirada,devolucao,inspecao_tecnica}', 'media', null, null, 3, true),
  ('equipamentos', 'Equipamentos', 20, 'eq_suporte_celular',  'Suporte do celular',  '{retirada,devolucao,inspecao_tecnica}', 'media', null, null, 4, true);
