-- Total por categoria, por ciclo e por tipo -- motor de calculo para o
-- ranking de "gastos por categoria" (Resumo). Agregacao e regra de negocio,
-- por isso vive aqui e nao no front-end; o front-end so decide quantas
-- categorias mostrar individualmente vs. agrupar em "Outras" (apresentacao,
-- nao calculo financeiro).
create view v_gastos_por_categoria with (security_invoker = true) as
select
  f.user_id,
  f.ciclo,
  f.categoria_id,
  c.nome as categoria_nome,
  f.tipo,
  sum(f.valor) as total
from v_fluxo f
join categorias c on c.id = f.categoria_id
where f.status is distinct from 'cancelado'
group by f.user_id, f.ciclo, f.categoria_id, c.nome, f.tipo;

grant select on v_gastos_por_categoria to authenticated;
