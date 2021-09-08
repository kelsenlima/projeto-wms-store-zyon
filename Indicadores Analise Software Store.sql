-- Romaneios --
select r.tiporomaneio, count(1) 
  from romaneio r 
 where r.codigoestabelecimento = 1
   and r.estadoromaneio <> 10
   and r.dataemissao >= '01/01/2014' and r.dataemissao <= '22/09/2014'
Group by r.tiporomaneio

-- Documento Saida --
select count(1) as Documentos, sum(ds.quantidadevolume), (sum(ds.pesobruto)/1000)
  from documentosaida ds
 where ds.codigoestabelecimento = 1
   and ds.estadodocumento = 23
   and ds.datageracao >= '01/01/2012' and ds.datageracao <= '31/12/2013'

-- Documento Entrada --
select count(1) as Documentos, sum(de.quantidadevolume), (sum(de.pesobruto)/1000)
  from documentoentrada de
 where de.estadodocumento in(23,25)
   and de.datageracao >= '01/01/2012' and de.datageracao <= '31/12/2013'   

-- Documento DOS --
select count(1) as Documento
  from documentooficialsaida dos
 where dos.codigoestabelecimento = 1
   and dos.estadodocumento = 37
   and dos.dataemissao >= '01/01/2014' and dos.dataemissao <= '31/12/2014'

-- Documento Rco --
select count(1) as Documento
  from documento d
 where d.codigoestabelecimento = 1
   and d.especiedocumento = 'RCO'
   and d.estadodocumento = 23
   and d.dataemissao >= '01/01/2014' and d.dataemissao <= '31/12/2014'

-- Documento Doe --
select count(1)
  from documentooficialentrada doe
 where doe.codigoestabelecimento = 1
   and doe.estadodocumento = 35
   and doe.dataemissao >= '01/01/2014' and doe.dataemissao <= '31/12/2014'

-- Sku --
select count(1)
  from produto p
 where exists ( select le.codigoproduto from loteentrada le where le.codigoempresa = p.codigoempresa and le.codigoproduto = p.codigoproduto group by le.codigoproduto )

-- Usuarios --
select count(1)
  from segusuario su
 where su.datacadastro >= '01/01/2014' and su.datacadastro <= '31/12/2014'


select * from estadodocumento

