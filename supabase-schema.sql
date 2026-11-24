-- ROBLOX CLUB production schema
-- Supabase SQL Editor에서 전체 실행. 공개 키만 프런트엔드에 사용하고 service_role 키는 절대 공개하지 마세요.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  nickname text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('member','admin'))
);
create table if not exists public.missions (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  category text not null default '커뮤니티',
  points integer not null check(points between 1 and 100000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.mission_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mission_id uuid not null references public.missions(id),
  proof text not null,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index if not exists one_live_submission_per_mission
on public.mission_submissions(user_id, mission_id)
where status in ('pending','approved');

create table if not exists public.point_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null,
  reason text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.rewards (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  cost integer not null check(cost > 0),
  active boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.redemption_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reward_id uuid not null references public.rewards(id),
  status text not null default 'pending' check(status in ('pending','approved','rejected','paid')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check(length(title) between 2 and 80),
  body text not null check(length(body) between 2 and 1500),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
declare uname text; nick text;
begin
  uname := lower(coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)));
  nick := coalesce(nullif(new.raw_user_meta_data->>'nickname',''), uname);
  insert into public.profiles(id,username,nickname) values(new.id,uname,nick);
  insert into public.user_roles(user_id,role) values(new.id,'member');
  return new;
end; $$;
drop trigger if exists on_auth_user_created_roblox_club on auth.users;
create trigger on_auth_user_created_roblox_club after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.user_roles where user_id=auth.uid() and role='admin');
$$;
create or replace function public.my_rank()
returns integer language sql stable security definer set search_path=public as $$
 with balances as (
  select user_id,coalesce(sum(amount),0) as points from public.point_transactions group by user_id
 ), mine as (select coalesce(points,0) p from balances where user_id=auth.uid())
 select case when auth.uid() is null then null else
  1 + (select count(*) from balances b where b.points > coalesce((select p from mine),0)) end;
$$;

create or replace function public.leaderboard()
returns table(place bigint, nickname text, points bigint)
language sql stable security definer set search_path=public as $$
 select row_number() over(order by coalesce(sum(pt.amount),0) desc, p.created_at asc) as place,
        p.nickname, coalesce(sum(pt.amount),0)::bigint as points
 from public.profiles p
 left join public.point_transactions pt on pt.user_id=p.id
 group by p.id,p.nickname,p.created_at
 order by place
 limit 50;
$$;

create or replace function public.admin_review_mission(p_submission_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare sub public.mission_submissions%rowtype; pts integer; title text;
begin
 if not public.is_admin() then raise exception '관리자 권한이 필요합니다.'; end if;
 select * into sub from public.mission_submissions where id=p_submission_id for update;
 if not found or sub.status <> 'pending' then raise exception '이미 처리됐거나 존재하지 않는 신청입니다.'; end if;
 if p_approve then
  select points,title into pts,title from public.missions where id=sub.mission_id;
  insert into public.point_transactions(user_id,amount,reason) values(sub.user_id,pts,'미션 승인: '||title);
  update public.mission_submissions set status='approved',reviewed_at=now() where id=p_submission_id;
 else
  update public.mission_submissions set status='rejected',reviewed_at=now() where id=p_submission_id;
 end if;
end; $$;

create or replace function public.admin_review_redemption(p_request_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=public as $$
declare req public.redemption_requests%rowtype; cost_value integer; current_points integer;
begin
 if not public.is_admin() then raise exception '관리자 권한이 필요합니다.'; end if;
 select * into req from public.redemption_requests where id=p_request_id for update;
 if not found or req.status <> 'pending' then raise exception '이미 처리됐거나 존재하지 않는 신청입니다.'; end if;
 if p_approve then
  perform 1 from auth.users where id=req.user_id for update;
  select cost into cost_value from public.rewards where id=req.reward_id and active=true;
  if cost_value is null then raise exception '보상이 비활성화됐거나 존재하지 않습니다.'; end if;
  select coalesce(sum(amount),0) into current_points from public.point_transactions where user_id=req.user_id;
  if current_points < cost_value then raise exception '회원 포인트가 부족합니다.'; end if;
  insert into public.point_transactions(user_id,amount,reason) values(req.user_id,-cost_value,'보상 교환 승인');
  update public.redemption_requests set status='approved',reviewed_at=now() where id=p_request_id;
 else
  update public.redemption_requests set status='rejected',reviewed_at=now() where id=p_request_id;
 end if;
end; $$;

alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.missions enable row level security;
alter table public.mission_submissions enable row level security;
alter table public.point_transactions enable row level security;
alter table public.rewards enable row level security;
alter table public.redemption_requests enable row level security;
alter table public.community_posts enable row level security;

drop policy if exists "profile read own or admin" on public.profiles;
create policy "profile read for community display" on public.profiles for select to authenticated using(true);
drop policy if exists "missions read active or admin" on public.missions;
create policy "missions read active or admin" on public.missions for select to authenticated using(active or public.is_admin());
drop policy if exists "missions admin manage" on public.missions;
create policy "missions admin manage" on public.missions for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "submission read own or admin" on public.mission_submissions;
create policy "submission read own or admin" on public.mission_submissions for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists "submission insert own pending" on public.mission_submissions;
create policy "submission insert own pending" on public.mission_submissions for insert to authenticated with check(user_id=auth.uid() and status='pending');
drop policy if exists "points read own or admin" on public.point_transactions;
create policy "points read own or admin" on public.point_transactions for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists "rewards read active or admin" on public.rewards;
create policy "rewards read active or admin" on public.rewards for select to authenticated using(active or public.is_admin());
drop policy if exists "rewards admin manage" on public.rewards;
create policy "rewards admin manage" on public.rewards for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "redemptions read own or admin" on public.redemption_requests;
create policy "redemptions read own or admin" on public.redemption_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
drop policy if exists "redemptions insert own pending" on public.redemption_requests;
create policy "redemptions insert own pending" on public.redemption_requests for insert to authenticated with check(user_id=auth.uid() and status='pending');
drop policy if exists "posts read all authenticated" on public.community_posts;
create policy "posts read all authenticated" on public.community_posts for select to authenticated using(true);
drop policy if exists "posts insert own" on public.community_posts;
create policy "posts insert own" on public.community_posts for insert to authenticated with check(user_id=auth.uid());

grant usage on schema public to authenticated;
grant select on public.profiles,public.missions,public.mission_submissions,public.point_transactions,public.rewards,public.redemption_requests,public.community_posts to authenticated;
grant insert on public.mission_submissions,public.redemption_requests,public.community_posts to authenticated;
grant insert,update,delete on public.missions,public.rewards to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.my_rank() to authenticated;
grant execute on function public.leaderboard() to authenticated;
grant execute on function public.admin_review_mission(uuid,boolean) to authenticated;
grant execute on function public.admin_review_redemption(uuid,boolean) to authenticated;

-- 예시 미션 3개 (필요하면 관리자 화면에서 추가/수정 가능)
insert into public.missions(title,description,category,points,active)
select v.title,v.description,v.category,v.points,true
from (values
 ('로블록스 게임 리뷰 작성','플레이한 게임의 장점과 아쉬운 점을 3문장 이상 작성해 인증해.','리뷰',30),
 ('초보자 공략 만들기','초보자가 알아두면 좋은 팁 3가지를 정리해 인증해.','공략',40),
 ('오늘의 창작 아이디어','새로운 게임/아이템 아이디어를 설명해 인증해.','창작',25)
) as v(title,description,category,points)
where not exists(select 1 from public.missions);
