-- Deterministic public generator point, synthetic auth salt, no provider traffic.
create function pg_temp.push_fixture_key() returns text language sql immutable as $$
 select rtrim(translate(replace(encode(decode('046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5','hex'),'base64'),E'\n',''),'+/','-_'),'=')
$$;
grant execute on function pg_temp.push_fixture_key() to authenticated;
