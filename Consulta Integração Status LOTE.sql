select count(*) 
  from xintegracao xi 
 where xi.tipointegracao = 341 
   and xi.estadointegracao = 1
   and xi.datalog >= '12/06/2016 00:00'
   and xi.datalog <= '16/06/2016 23:59'

update xintegracao xi set xi.estadointegracao = 3
where xi.tipointegracao = 341 
   and xi.estadointegracao = 1
   and xi.datalog >= '14/06/2016 00:00'
   and xi.datalog <= '1/06/2016 23:59'

select * from xestadointegracao 
select count(*) from xintegracaohistorico xih where xih.dataprocessamento <= '30/06/2015 23:59'
