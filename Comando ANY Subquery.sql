select * from ediregistro edi 
where edi.datalog >= '01/05/2016'
  and edi.tipointegracao = 2
  and edi.dado002 = '62432778000127'
 
select * from estadointegracao

delete from ediregistro edi 
where edi.datalog >= '01/05/2016'
  and edi.tipointegracao = 2
  and edi.dado002 = '62432778000127'
  
 
select * from documentosaida ds
where ds.documentosaida = ANY (select edi.dado006 from ediregistro edi where edi.tipointegracao = 1004 and edi.datalog >= '30/05/2016')
