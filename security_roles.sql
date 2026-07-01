-- 1. Создание ролей
create role admin_role;
create role operator_role;
create role guest_role;

-- Права для admin (Полный доступ ко всему)
grant all privileges on all tables in schema public to admin_role;
grant all privileges on all sequences in schema public to admin_role;

-- Права для operator (Общие права, ограничения в RLS)
grant select, update on hotels, room_types, rooms, bookings to operator_role;
grant select on guests, amenities, room_amenities to operator_role;
grant usage on all sequences in schema public to operator_role;

-- Права для guest (Может смотреть отели/номера и управлять своими бронями)
grant select on hotels, room_types, rooms, amenities, room_amenities to guest_role;
grant select, insert, update on bookings to guest_role; 
grant select on guests to guest_role;
grant usage on all sequences in schema public to guest_role;

-- Право всем ролям выполнять функции бизнес логики
grant execute on all functions in schema public to admin_role, operator_role, guest_role;

-- Включаем RLS на таблицы, где нужен контекст пользователя
alter table hotels enable row level security;
alter table bookings enable row level security;


-- Политики для отелей
-- Администратор видит всё
create policy hotel_admin_policy on hotels 
    for all to admin_role using (true);

-- Гость может видеть любые отели (чтобы искать номера)
create policy hotel_guest_policy on hotels 
    for select to guest_role using (true);

-- Оператор видит и обновляет ТОЛЬКО СВОЙ отель (operator_id равен его id в базе)
-- Для теста предполагаем, что имя учетной записи в Postgres совпадает с email или именем в таблице guests
create policy hotel_operator_policy on hotels 
    for all to operator_role 
    using (operator_id = (select id from guests where name = current_setting('app.current_user_name', true)));


-- Политики для бронирования
-- Администратор видит все бронирования
create policy booking_admin_policy on bookings 
    for all to admin_role using (true);

-- Гость видит и управляет только своими бронированиями 
create policy booking_guest_policy on bookings 
    for all to guest_role 
    using (guest_id = (select id from guests where name = current_setting('app.current_user_name', true)));

-- Оператор видит бронирования только тех номеров, которые принадлежат его отелям
create policy booking_operator_policy on bookings 
    for all to operator_role 
    using (
        room_id in (
            select r.id 
            from rooms r
            join room_types rt on r.room_type_id = rt.id
            join hotels h on rt.hotel_id = h.id
            where h.operator_id = (select id from guests where name = current_setting('app.current_user_name', true))
        )
    );