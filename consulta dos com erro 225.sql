FC_092_REMOVE_ACENTOS

select ne.descricaoestado, dos.documentooficialsaida, dos.nfeestado,
       dos.descricaomensagemcontribuinte, dos.dataemissao, dos.pesobruto, dos.pesoliquido
 from documentooficialsaida dos, nfeestado ne
where dos.nfeestado = ne.nfeestado
  and dos.codigoestabelecimento = 1
  and dos.nfeestado = 225
  and dos.nfeestado <> 100 and dos.nfeestado <> 101 and dos.nfeestado <> 102
  --and dos.descricaomensagemcontribuinte like '%ANHANGAœERA%'
  and dos.documentooficialsaida in ('000169025') 

update documentooficialsaida dos
   set dos.descricaomensagemcontribuinte = FC_092_REMOVE_ACENTOS(dos.descricaomensagemcontribuinte)
where dos.codigoestabelecimento = 1
  and dos.nfeestado = 225
  and dos.documentooficialsaida = '000167363'
  
update documentooficialsaida dos set dos.nfeestado = 1 
where dos.codigoestabelecimento = 1
  and dos.nfeestado = 225
  and dos.documentooficialsaida = '000169025'
  
select count(dos.descricaomensagemcontribuinte)
 from documentooficialsaida dos
where dos.codigoestabelecimento = 1
  and dos.nfeestado = 2
