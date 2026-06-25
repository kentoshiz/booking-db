-- 1. Генерируем 50 000 пользователей (смесь гостей и операторов)
insert into users (name, email, role)
select 
    'User_' || i,
    'user_' || i || '@testmail.com',
    case 
        when i % 10 = 0 then 'operator'::user_role
        when i % 50 = 0 then 'admin'::user_role
        else 'guest'::user_role
    end
from generate_series(1, 50000) as i;

-- 2. Генерируем 5 000 отелей по разным городам
insert into hotels (name, city, rating, operator_id)
select 
    'Hotel_' || i,
    (array['Москва', 'Санкт-Петербург', 'Казань', 'Сочи', 'Новосибирск'])[floor(random() * 5) + 1],
    round((3.0 + random() * 2.0)::numeric, 1),
    (select id from users where role = 'operator' order by random() limit 1)
from generate_series(1, 50000) as i
limit 5000; -- привязываем к случайным операторам

-- 3. Создаем типы номеров для каждого отеля (примерно по 3 типа на отель)
insert into room_types (hotel_id, name, base_price, capacity)
select 
    h.id,
    t.name,
    t.price,
    t.cap
from hotels h
cross join (
    values 
    ('Стандарт', 3000.00, 2),
    ('Комфорт', 5000.00, 3),
    ('Люкс', 10000.00, 4)
) as t(name, price, cap);

-- 4. Генерируем физические комнаты (по 10 штук на каждый тип номера)
insert into rooms (room_number, room_type_id)
select 
    '№' || (100 + room_seq),
    rt.id
from room_types rt
cross join generate_series(1, 10) as room_seq;

-- 5. Заполняем справочник удобств
insert into amenities (name) values 
('Wi-Fi'), ('Кондиционер'), ('Завтрак включен'), ('Парковка'), ('Бассейн');

-- Навешиваем удобства на типы номеров
insert into room_amenities (room_type_id, amenity_id)
select rt.id, a.id 
from room_types rt 
cross join amenities a 
where random() > 0.4;


-- 6. Генерируем 5 000 000 бронирований
-- Распределяем даты заезда строго на лето 2026 года, чтобы они красиво легли в наши партиции
insert into bookings (id, check_in, guest_id, room_id, check_out, status, price_at_booking)
select 
    i as id,
    gen_date as check_in,
    (select id from users where role = 'guest' limit 1 offset floor(random() * 40000)) as guest_id,
    (select id from rooms limit 1 offset floor(random() * 150000)) as room_id,
    gen_date + (floor(random() * 7) + 1)::int as check_out,
    (array['confirmed', 'confirmed', 'cancelled', 'pending'])[floor(random() * 4) + 1] as status,
    (2500 + floor(random() * 8000))::numeric as price_at_booking
from generate_series(1, 5000000) as i
cross join lateral (
    select '2026-06-01'::date + floor(random() * 90)::int as gen_date
) as d;