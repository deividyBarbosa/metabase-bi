-- =====================================================================
-- Dashboard Olist (E-commerce brasileiro) - Metabase + PostgreSQL
-- Banco de dados: "dados"
--
-- Como usar:
--   1) Rode o carregar_dados.py para criar as tabelas base.
--   2) Execute a PARTE 1 (views) no psql, em ordem:
--        docker exec -it bi-postgres psql -U postgres -d dados
--   3) No Metabase, sincronize o banco (Admin > Databases > dados >
--      Sync database schema now).
--   4) Crie cada pergunta da PARTE 2 como "Consulta SQL" nativa.
--
-- Nas perguntas, {{periodo}}, {{estado}} e {{categoria}} sao variaveis
-- do tipo "Field Filter" do Metabase, mapeadas para as colunas da view
-- usada na query. Os blocos [[ ... ]] sao opcionais: se o filtro nao for
-- selecionado no dashboard, o bloco inteiro e ignorado.
-- =====================================================================


-- =====================================================================
-- PARTE 1 - VIEWS
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.1 vw_vendas: uma linha por ITEM de pedido, ja com joins e metricas
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_vendas AS
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.seller_id,
    o.customer_id,
    c.customer_state                         AS estado,
    c.customer_city                          AS cidade,
    o.order_status                           AS status,
    o.order_purchase_timestamp               AS data_compra,
    o.order_delivered_customer_date          AS data_entrega,
    o.order_estimated_delivery_date          AS data_estimada,
    oi.price                                 AS preco,
    oi.freight_value                         AS frete,
    COALESCE(t.product_category_name_english,
             p.product_category_name,
             'unknown')                      AS categoria,
    EXTRACT(DAY FROM (o.order_delivered_customer_date
                      - o.order_purchase_timestamp))      AS dias_entrega,
    EXTRACT(DAY FROM (o.order_delivered_customer_date
                      - o.order_estimated_delivery_date)) AS dias_atraso
FROM order_items oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN customers c  ON c.customer_id = o.customer_id
LEFT JOIN products p ON p.product_id = oi.product_id
LEFT JOIN category_translation t
       ON t.product_category_name = p.product_category_name;


-- ---------------------------------------------------------------------
-- 1.2 vw_avaliacoes: uma linha por pedido (alguns pedidos tem varias
--     avaliacoes, entao tiramos a media)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_avaliacoes AS
SELECT order_id, AVG(review_score) AS nota
FROM order_reviews
GROUP BY order_id;


-- ---------------------------------------------------------------------
-- 1.3 vw_vendas_validas: itens de pedidos validos, jan/2017 a ago/2018
--     (usada em receita, categorias e receita por estado)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_vendas_validas AS
SELECT * FROM vw_vendas
WHERE status NOT IN ('canceled', 'unavailable')
  AND data_compra >= '2017-01-01'
  AND data_compra <  '2018-09-01';


-- ---------------------------------------------------------------------
-- 1.4 vw_pedidos: uma linha por PEDIDO (usada em entrega, atraso,
--     nota e ticket medio, para nao contar pedidos com varios itens
--     mais de uma vez)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_pedidos AS
SELECT
    o.order_id,
    c.customer_state                      AS estado,
    o.order_status                        AS status,
    o.order_purchase_timestamp            AS data_compra,
    v.receita,
    v.frete,
    EXTRACT(DAY FROM (o.order_delivered_customer_date
                      - o.order_purchase_timestamp))            AS dias_entrega,
    (o.order_delivered_customer_date
        > o.order_estimated_delivery_date)                      AS atrasado,
    CEIL(EXTRACT(EPOCH FROM (o.order_delivered_customer_date
                      - o.order_estimated_delivery_date)) / 86400) AS dias_atraso,
    a.nota
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
LEFT JOIN (
    SELECT order_id, SUM(price) AS receita, SUM(freight_value) AS frete
    FROM order_items GROUP BY order_id
) v ON v.order_id = o.order_id
LEFT JOIN vw_avaliacoes a ON a.order_id = o.order_id
WHERE o.order_status NOT IN ('canceled', 'unavailable')
  AND o.order_purchase_timestamp >= '2017-01-01'
  AND o.order_purchase_timestamp <  '2018-09-01';


-- =====================================================================
-- PARTE 2 - PERGUNTAS DO DASHBOARD (Metabase, consulta SQL nativa)
-- =====================================================================

-- ---------------------------------------------------------------------
-- P1. Receita mensal (grafico de linha)
-- Variaveis: periodo -> vw_vendas_validas.data_compra
--            estado -> vw_vendas_validas.estado
--            categoria -> vw_vendas_validas.categoria
-- ---------------------------------------------------------------------
SELECT DATE_TRUNC('month', data_compra)::date AS mes,
       SUM(preco) AS receita
FROM vw_vendas_validas
WHERE true
  [[AND {{periodo}}]] [[AND {{estado}}]] [[AND {{categoria}}]]
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- P2. Top 10 categorias por receita (barras horizontais)
-- Variaveis: periodo, estado -> vw_vendas_validas
-- ---------------------------------------------------------------------
SELECT categoria, SUM(preco) AS receita
FROM vw_vendas_validas
WHERE true
  [[AND {{periodo}}]] [[AND {{estado}}]]
GROUP BY categoria
ORDER BY receita DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- P3. Receita por estado (barras ou mapa de regioes)
-- Variaveis: periodo, categoria -> vw_vendas_validas
-- Mapa: Visualization > Map > Region map > "Brasil - Estados"
--       (identificador do GeoJSON = sigla da UF)
-- ---------------------------------------------------------------------
SELECT estado, SUM(preco) AS receita
FROM vw_vendas_validas
WHERE true
  [[AND {{periodo}}]] [[AND {{categoria}}]]
GROUP BY estado
ORDER BY receita DESC;


-- ---------------------------------------------------------------------
-- P4. Tempo medio de entrega por estado (barras ou mapa)
-- Variaveis: periodo, estado -> vw_pedidos
-- ---------------------------------------------------------------------
SELECT estado,
       ROUND(AVG(dias_entrega)::numeric, 1) AS dias_medios
FROM vw_pedidos
WHERE status = 'delivered'
  AND dias_entrega IS NOT NULL
  [[AND {{periodo}}]] [[AND {{estado}}]]
GROUP BY estado
ORDER BY dias_medios DESC;


-- ---------------------------------------------------------------------
-- P5. Percentual geral de pedidos entregues com atraso (cartao)
-- Variaveis: periodo, estado -> vw_pedidos
-- ---------------------------------------------------------------------
SELECT ROUND(100.0 * AVG(atrasado::int), 1) AS pct_atrasados
FROM vw_pedidos
WHERE status = 'delivered'
  AND atrasado IS NOT NULL
  [[AND {{periodo}}]] [[AND {{estado}}]];


-- ---------------------------------------------------------------------
-- P6a. Nota media geral de avaliacao (cartao)
-- Variaveis: periodo, estado -> vw_pedidos
-- ---------------------------------------------------------------------
SELECT ROUND(AVG(nota)::numeric, 2) AS nota_media
FROM vw_pedidos
WHERE nota IS NOT NULL
  [[AND {{periodo}}]] [[AND {{estado}}]];


-- ---------------------------------------------------------------------
-- P6b. Nota media por faixa de atraso (barras)
-- Variaveis: periodo, estado -> vw_pedidos
-- Os prefixos numericos so servem para ordenar as barras.
-- Na visualizacao, deixe apenas nota_media no eixo Y.
-- ---------------------------------------------------------------------
SELECT CASE
         WHEN NOT atrasado     THEN '1. No prazo'
         WHEN dias_atraso <= 3 THEN '2. Atraso de 1 a 3 dias'
         WHEN dias_atraso <= 7 THEN '3. Atraso de 4 a 7 dias'
         ELSE                       '4. Atraso de mais de 7 dias'
       END AS situacao,
       ROUND(AVG(nota)::numeric, 2) AS nota_media,
       COUNT(*)                     AS pedidos
FROM vw_pedidos
WHERE status = 'delivered'
  AND atrasado IS NOT NULL
  AND nota IS NOT NULL
  [[AND {{periodo}}]] [[AND {{estado}}]]
GROUP BY 1
ORDER BY 1;



