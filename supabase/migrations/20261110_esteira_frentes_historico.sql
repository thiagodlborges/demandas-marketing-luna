-- =====================================================================
-- Demandas de Marketing — Esteira, Frentes e Quadro (histórico)
--  1. Frentes: além de lojas, é possível cadastrar outras frentes.
--  2. Esteira: prioridade, prazo de início e de conclusão (agência), paralelo.
--  3. Quadro: histórico de atualizações de cada ação, sempre com motivo.
--  4. Conclusão: campo de resultado + histórico de ações concluídas.
-- Aditiva: não remove nem renomeia nada existente. A coluna "loja" de
-- marketing_demandas passa a representar a FRENTE (nome mantido p/ compatibilidade)
-- e "prazo" passa a ser o prazo de CONCLUSÃO previsto.
-- =====================================================================

-- ---------- 1. Frentes ----------
create table if not exists public.marketing_frentes (
  nome      text primary key,
  tipo      text not null default 'loja' check (tipo in ('loja','outra')),
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);
alter table public.marketing_frentes enable row level security;

drop policy if exists marketing_frentes_select on public.marketing_frentes;
create policy marketing_frentes_select on public.marketing_frentes
  for select to authenticated using (true);
drop policy if exists marketing_frentes_insert on public.marketing_frentes;
create policy marketing_frentes_insert on public.marketing_frentes
  for insert to authenticated with check (is_master() or is_marketing_backoffice());
drop policy if exists marketing_frentes_update on public.marketing_frentes;
create policy marketing_frentes_update on public.marketing_frentes
  for update to authenticated
  using (is_master() or is_marketing_backoffice())
  with check (is_master() or is_marketing_backoffice());

insert into public.marketing_frentes (nome, tipo) values
  ('Esplanada','loja'),('Cianê','loja'),('Tucuruvi','loja'),('Indaiatuba','loja'),
  ('Jundiaí','loja'),('Praça da Moça - Diadema','loja'),('Buriti Mogi Guaçu','loja'),
  ('SP Market','loja'),('Iguatemi Campinas','loja'),('Shopping Itaquera','loja'),('Atrium','loja')
on conflict (nome) do nothing;

-- qualquer valor já usado em demandas passa a existir como frente
insert into public.marketing_frentes (nome, tipo)
  select distinct loja, 'loja' from public.marketing_demandas
on conflict (nome) do nothing;

do $$ begin
  alter table public.marketing_demandas
    add constraint marketing_demandas_frente_fk
    foreign key (loja) references public.marketing_frentes(nome) on update cascade;
exception when duplicate_object then null; end $$;

-- ---------- 2. Esteira: novas colunas ----------
alter table public.marketing_demandas
  add column if not exists prioridade         smallint not null default 3,
  add column if not exists prazo_inicio       date,
  add column if not exists em_paralelo        boolean  not null default false,
  add column if not exists concluida_em       date,
  add column if not exists conclusao_resultado text,
  add column if not exists concluida_por_nome text;

do $$ begin
  alter table public.marketing_demandas
    add constraint marketing_demandas_prioridade_chk check (prioridade between 1 and 4);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.marketing_demandas
    add constraint marketing_demandas_prazos_chk
    check (prazo_inicio is null or prazo is null or prazo >= prazo_inicio);
exception when duplicate_object then null; end $$;

update public.marketing_demandas
   set concluida_em = atualizado_em::date
 where status = 'concluido' and concluida_em is null;

-- ---------- 3. Quadro: histórico ----------
create table if not exists public.marketing_demanda_historico (
  id                 uuid primary key default gen_random_uuid(),
  demanda_id         uuid not null references public.marketing_demandas(id) on delete cascade,
  tipo               text not null check (tipo in (
                       'criacao','nota','revisao_solicitada','ajuste_prazo','prioridade',
                       'status','paralelo','furou_fila','empurrada','conclusao','reabertura')),
  motivo             text,
  detalhe            text,
  prazo_inicio_de    date,
  prazo_inicio_para  date,
  prazo_de           date,
  prazo_para         date,
  prioridade_de      smallint,
  prioridade_para    smallint,
  status_de          text,
  status_para        text,
  em_paralelo_para   boolean,
  origem_demanda_id  uuid references public.marketing_demandas(id) on delete set null,
  autor_id           uuid default auth.uid(),
  autor_nome         text,
  criado_em          timestamptz not null default now()
);
create index if not exists marketing_demanda_historico_demanda_idx
  on public.marketing_demanda_historico (demanda_id, criado_em desc);

alter table public.marketing_demanda_historico enable row level security;
-- leitura: quem enxerga a demanda (o sub-select respeita a RLS da demanda).
-- Sem policies de escrita: toda escrita passa pelas funções abaixo.
drop policy if exists marketing_historico_select on public.marketing_demanda_historico;
create policy marketing_historico_select on public.marketing_demanda_historico
  for select to authenticated
  using (exists (select 1 from public.marketing_demandas d where d.id = demanda_id));

create index if not exists marketing_demandas_esteira_idx
  on public.marketing_demandas (status, em_paralelo, prioridade, prazo_inicio);

-- ---------- Trigger: protege a esteira ----------
-- Prazos, prioridade, paralelo, status e conclusão só mudam pelas funções
-- marketing_* (que exigem motivo e gravam o histórico).
create or replace function public.fn_marketing_demandas_esteira()
returns trigger language plpgsql set search_path = public as $$
declare v_rpc boolean := coalesce(current_setting('luna.esteira_rpc', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    if not v_rpc then
      new.status := 'planejado';
      new.concluida_em := null; new.conclusao_resultado := null; new.concluida_por_nome := null;
      if not (is_master() or is_marketing_backoffice()) then
        new.prioridade := 3; new.em_paralelo := false;
      end if;
    end if;
    return new;
  end if;

  if not v_rpc and (
       new.prioridade   is distinct from old.prioridade
    or new.prazo_inicio is distinct from old.prazo_inicio
    or new.prazo        is distinct from old.prazo
    or new.em_paralelo  is distinct from old.em_paralelo
    or new.status       is distinct from old.status
    or new.concluida_em is distinct from old.concluida_em
    or new.conclusao_resultado is distinct from old.conclusao_resultado
    or new.concluida_por_nome  is distinct from old.concluida_por_nome) then
    raise exception 'Prazos, prioridade, status e conclusão são alterados pelo quadro da ação (com motivo).'
      using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_marketing_demandas_esteira on public.marketing_demandas;
create trigger trg_marketing_demandas_esteira
  before insert or update on public.marketing_demandas
  for each row execute function public.fn_marketing_demandas_esteira();

-- registro automático da criação
create or replace function public.fn_marketing_demandas_historico_criacao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into marketing_demanda_historico
    (demanda_id, tipo, motivo, prazo_inicio_para, prazo_para, prioridade_para, status_para,
     em_paralelo_para, autor_id, autor_nome, criado_em)
  values
    (new.id, 'criacao', 'Ação cadastrada', new.prazo_inicio, new.prazo, new.prioridade, new.status,
     new.em_paralelo, coalesce(new.solicitado_por, auth.uid()),
     coalesce(new.solicitado_por_nome, (select nome from perfis where id = auth.uid())),
     new.criado_em);
  return new;
end $$;

drop trigger if exists trg_marketing_demandas_historico_criacao on public.marketing_demandas;
create trigger trg_marketing_demandas_historico_criacao
  after insert on public.marketing_demandas
  for each row execute function public.fn_marketing_demandas_historico_criacao();

-- histórico retroativo das ações já existentes
insert into public.marketing_demanda_historico
  (demanda_id, tipo, motivo, prioridade_para, status_para, autor_id, autor_nome, criado_em)
select d.id, 'criacao', 'Ação cadastrada', d.prioridade, 'planejado', d.solicitado_por, d.solicitado_por_nome, d.criado_em
from public.marketing_demandas d
where not exists (select 1 from public.marketing_demanda_historico h where h.demanda_id = d.id);

insert into public.marketing_demanda_historico
  (demanda_id, tipo, motivo, status_de, status_para, criado_em)
select d.id, 'conclusao', 'Conclusão registrada antes do módulo de esteira', 'em_andamento', 'concluido', d.atualizado_em
from public.marketing_demandas d
where d.status = 'concluido'
  and not exists (select 1 from public.marketing_demanda_historico h where h.demanda_id = d.id and h.tipo = 'conclusao');

-- ---------- Funções (único caminho de escrita da esteira) ----------

-- 3.1 Atualização do quadro: nota, revisão solicitada, ajuste de prazo/prioridade/status/paralelo.
create or replace function public.marketing_alterar_esteira(
  p_demanda      uuid,
  p_tipo         text,
  p_motivo       text,
  p_prazo_inicio date,
  p_prazo        date,
  p_prioridade   smallint,
  p_em_paralelo  boolean,
  p_status       text
) returns void language plpgsql security definer set search_path = public as $$
declare
  d marketing_demandas;
  v_gestor boolean := is_master() or is_marketing_backoffice();
  v_mudou boolean;
  v_tipo text := p_tipo;
  v_nome text;
begin
  select * into d from marketing_demandas where id = p_demanda for update;
  if not found then raise exception 'Ação não encontrada.'; end if;
  if not (v_gestor or tem_acesso_loja(d.loja)) then
    raise exception 'Sem acesso a esta ação.' using errcode = '42501';
  end if;
  if btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Informe o motivo da atualização.';
  end if;
  if v_tipo not in ('nota','revisao_solicitada','ajuste_prazo','prioridade','status','paralelo') then
    raise exception 'Tipo de atualização inválido.';
  end if;
  if p_status = 'concluido' then
    raise exception 'Para concluir use "Concluir ação".';
  end if;
  if p_prioridade not between 1 and 4 then raise exception 'Prioridade inválida.'; end if;
  if p_prazo_inicio is not null and p_prazo is not null and p_prazo < p_prazo_inicio then
    raise exception 'O prazo de conclusão não pode ser anterior ao prazo de início.';
  end if;

  v_mudou := p_prazo_inicio is distinct from d.prazo_inicio
          or p_prazo        is distinct from d.prazo
          or p_prioridade   is distinct from d.prioridade
          or p_em_paralelo  is distinct from d.em_paralelo
          or p_status       is distinct from d.status;

  if v_mudou and not v_gestor then
    raise exception 'Somente o marketing altera prazos, prioridade e status.' using errcode = '42501';
  end if;
  if not v_mudou and v_tipo not in ('nota','revisao_solicitada') then
    raise exception 'Nenhum campo foi alterado.';
  end if;

  select nome into v_nome from perfis where id = auth.uid();
  perform set_config('luna.esteira_rpc', '1', true);

  -- reabertura: voltar de concluído para outro status
  if d.status = 'concluido' and p_status <> 'concluido' then
    v_tipo := 'reabertura';
    update marketing_demandas set
      prazo_inicio = p_prazo_inicio, prazo = p_prazo, prioridade = p_prioridade,
      em_paralelo = p_em_paralelo, status = p_status,
      concluida_em = null, conclusao_resultado = null, concluida_por_nome = null
    where id = p_demanda;
  elsif v_mudou then
    update marketing_demandas set
      prazo_inicio = p_prazo_inicio, prazo = p_prazo, prioridade = p_prioridade,
      em_paralelo = p_em_paralelo, status = p_status
    where id = p_demanda;
  end if;

  insert into marketing_demanda_historico
    (demanda_id, tipo, motivo, prazo_inicio_de, prazo_inicio_para, prazo_de, prazo_para,
     prioridade_de, prioridade_para, status_de, status_para, em_paralelo_para, autor_id, autor_nome)
  values
    (p_demanda, v_tipo, btrim(p_motivo),
     d.prazo_inicio, p_prazo_inicio, d.prazo, p_prazo,
     d.prioridade, p_prioridade, d.status, p_status, p_em_paralelo, auth.uid(), v_nome);
end $$;

-- 3.2 Conclusão (campo de conclusão + registro no histórico)
create or replace function public.marketing_concluir(
  p_demanda   uuid,
  p_data      date,
  p_resultado text
) returns void language plpgsql security definer set search_path = public as $$
declare d marketing_demandas; v_nome text;
begin
  select * into d from marketing_demandas where id = p_demanda for update;
  if not found then raise exception 'Ação não encontrada.'; end if;
  if not (is_master() or is_marketing_backoffice() or tem_acesso_loja(d.loja)) then
    raise exception 'Sem acesso a esta ação.' using errcode = '42501';
  end if;
  if d.status = 'concluido' then raise exception 'Esta ação já está concluída.'; end if;
  if d.status = 'cancelado' then raise exception 'Reative a ação antes de concluir.'; end if;
  if btrim(coalesce(p_resultado, '')) = '' then
    raise exception 'Descreva o resultado / conclusão da ação.';
  end if;

  select nome into v_nome from perfis where id = auth.uid();
  perform set_config('luna.esteira_rpc', '1', true);

  update marketing_demandas set
    status = 'concluido',
    concluida_em = coalesce(p_data, current_date),
    conclusao_resultado = btrim(p_resultado),
    concluida_por_nome = v_nome
  where id = p_demanda;

  insert into marketing_demanda_historico
    (demanda_id, tipo, motivo, status_de, status_para, autor_id, autor_nome)
  values (p_demanda, 'conclusao', btrim(p_resultado), d.status, 'concluido', auth.uid(), v_nome);
end $$;

-- 3.3 Furar a fila: empurra as demais OU roda em paralelo. p_simular só calcula o impacto.
create or replace function public.marketing_furar_fila(
  p_demanda      uuid,
  p_modo         text,           -- 'empurrar' | 'paralelo'
  p_dias         int,            -- dias corridos a empurrar (modo 'empurrar')
  p_motivo       text,
  p_prazo_inicio date default null,
  p_prazo        date default null,
  p_simular      boolean default false
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d marketing_demandas;
  v_inicio date; v_fim date; v_ref date;
  v_afetadas jsonb := '[]'::jsonb;
  v_nome text; v_n int := 0; r record; v_det text;
begin
  if not (is_master() or is_marketing_backoffice()) then
    raise exception 'Somente o marketing gerencia a esteira.' using errcode = '42501';
  end if;
  if p_modo not in ('empurrar','paralelo') then raise exception 'Modo inválido.'; end if;

  select * into d from marketing_demandas where id = p_demanda for update;
  if not found then raise exception 'Ação não encontrada.'; end if;
  if d.status not in ('planejado','em_andamento') then
    raise exception 'Só é possível furar a fila com ações planejadas ou em andamento.';
  end if;
  if not p_simular and btrim(coalesce(p_motivo, '')) = '' then
    raise exception 'Informe o motivo para furar a fila.';
  end if;

  v_inicio := coalesce(p_prazo_inicio, d.prazo_inicio);
  v_fim    := coalesce(p_prazo, d.prazo);
  if v_inicio is not null and v_fim is not null and v_fim < v_inicio then
    raise exception 'O prazo de conclusão não pode ser anterior ao prazo de início.';
  end if;
  v_ref := coalesce(v_inicio, current_date);

  if p_modo = 'empurrar' then
    if coalesce(p_dias, 0) < 1 then raise exception 'Informe quantos dias empurrar (mínimo 1).'; end if;
    -- Planejadas: deslocam início e conclusão. Em andamento: só a conclusão (o trabalho é interrompido).
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'nome_acao', x.nome_acao, 'loja', x.loja, 'status', x.status,
        'inicio_de', x.prazo_inicio,
        'inicio_para', case when x.status = 'planejado' and x.prazo_inicio is not null
                            then x.prazo_inicio + p_dias else x.prazo_inicio end,
        'prazo_de', x.prazo,
        'prazo_para', case when x.prazo is not null then x.prazo + p_dias else null end)
      order by coalesce(x.prazo_inicio, x.prazo)), '[]'::jsonb)
    into v_afetadas
    from marketing_demandas x
    where x.id <> p_demanda
      and not x.em_paralelo
      and ((x.status = 'planejado'    and coalesce(x.prazo_inicio, x.prazo) >= v_ref)
        or (x.status = 'em_andamento' and coalesce(x.prazo, x.prazo_inicio) >= v_ref));
  end if;

  if p_simular then
    return jsonb_build_object('aplicado', false, 'afetadas', v_afetadas);
  end if;

  select nome into v_nome from perfis where id = auth.uid();
  perform set_config('luna.esteira_rpc', '1', true);

  for r in select * from jsonb_to_recordset(v_afetadas)
           as t(id uuid, inicio_de date, inicio_para date, prazo_de date, prazo_para date)
  loop
    update marketing_demandas set prazo_inicio = r.inicio_para, prazo = r.prazo_para where id = r.id;
    insert into marketing_demanda_historico
      (demanda_id, tipo, motivo, detalhe, prazo_inicio_de, prazo_inicio_para, prazo_de, prazo_para,
       origem_demanda_id, autor_id, autor_nome)
    values
      (r.id, 'empurrada', btrim(p_motivo),
       format('Empurrada em %s dia(s) porque "%s" (%s) furou a fila', p_dias, d.nome_acao, d.loja),
       r.inicio_de, r.inicio_para, r.prazo_de, r.prazo_para, p_demanda, auth.uid(), v_nome);
    v_n := v_n + 1;
  end loop;

  update marketing_demandas set
    prioridade = 1, em_paralelo = (p_modo = 'paralelo'),
    prazo_inicio = v_inicio, prazo = v_fim
  where id = p_demanda;

  v_det := case when p_modo = 'paralelo'
    then 'Executada em paralelo — prazos das demais ações mantidos'
    else format('Furou a fila — %s ação(ões) empurrada(s) em %s dia(s)', v_n, p_dias) end;

  insert into marketing_demanda_historico
    (demanda_id, tipo, motivo, detalhe, prazo_inicio_de, prazo_inicio_para, prazo_de, prazo_para,
     prioridade_de, prioridade_para, status_de, status_para, em_paralelo_para, autor_id, autor_nome)
  values
    (p_demanda, 'furou_fila', btrim(p_motivo), v_det, d.prazo_inicio, v_inicio, d.prazo, v_fim,
     d.prioridade, 1, d.status, d.status, (p_modo = 'paralelo'), auth.uid(), v_nome);

  return jsonb_build_object('aplicado', true, 'afetadas', v_afetadas);
end $$;

revoke all on function public.marketing_alterar_esteira(uuid,text,text,date,date,smallint,boolean,text) from public, anon;
revoke all on function public.marketing_concluir(uuid,date,text) from public, anon;
revoke all on function public.marketing_furar_fila(uuid,text,int,text,date,date,boolean) from public, anon;
grant execute on function public.marketing_alterar_esteira(uuid,text,text,date,date,smallint,boolean,text) to authenticated;
grant execute on function public.marketing_concluir(uuid,date,text) to authenticated;
grant execute on function public.marketing_furar_fila(uuid,text,int,text,date,date,boolean) to authenticated;
