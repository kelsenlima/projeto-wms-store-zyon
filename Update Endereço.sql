select * from texto1 for update
truncate table texto1

select * from texto1 t1, endereco e
where e.etiquetaendereco (+)= t1.texto
  and e.codigoestabelecimento is null
  
UPDATE ENDERECO E
   SET E.ESPECIEENDERECO=17
 WHERE E.ETIQUETAENDERECO IN (SELECT TEXTO FROM TEXTO1)
