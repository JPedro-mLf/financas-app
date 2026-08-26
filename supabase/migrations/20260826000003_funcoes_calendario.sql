-- Funcoes de calendario (ESPECIFICACAO.md secao 5).
-- Copiadas fielmente da especificacao: é o contrato do projeto.
-- Premissa embutida: dia_vencimento < dia_fechamento (03 < 27), portanto o
-- vencimento cai sempre no mes seguinte ao fechamento. Se isso mudar, revisar fatura_vence.

-- Data de recebimento do salario em um dado mes
create or replace function data_recebimento(mes date)
returns date language sql immutable as $$
  select case extract(isodow from d)
           when 6 then d - 1   -- sabado  -> sexta anterior
           when 7 then d - 2   -- domingo -> sexta anterior
           else d
         end
  from (select (date_trunc('month', mes) + interval '1 month - 2 days')::date as d) t;
$$;

-- Ciclo ao qual uma data de caixa pertence.
-- Retorna o primeiro dia do MES-ROTULO do ciclo.
create or replace function ciclo(d date)
returns date language sql immutable as $$
  select case when d >= data_recebimento(d)
              then (date_trunc('month', d) + interval '1 month')::date
              else  date_trunc('month', d)::date
         end;
$$;

-- Data de fechamento da fatura que captura uma compra
create or replace function fatura_fecha(compra date)
returns date language sql stable as $$
  select case when extract(day from compra) <= c.dia_fechamento
              then  date_trunc('month', compra)::date + (c.dia_fechamento - 1)
              else (date_trunc('month', compra) + interval '1 month')::date
                     + (c.dia_fechamento - 1)
         end
  from config c;
$$;

-- Vencimento da fatura que captura uma compra
create or replace function fatura_vence(compra date)
returns date language sql stable as $$
  select (date_trunc('month', fatura_fecha(compra)) + interval '1 month')::date
         + (c.dia_vencimento - 1)
  from config c;
$$;

-- Ciclo de caixa de qualquer lancamento
create or replace function ciclo_caixa(d date, meio meio_pagamento)
returns date language sql stable as $$
  select case when meio = 'credito' then ciclo(fatura_vence(d))
              else ciclo(d) end;
$$;
