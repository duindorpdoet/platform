import { randomUUID } from "node:crypto";
import { sql, requireLocalTogetherDatabase } from "./together-fixtures.mjs";
export function createPortalRoomFixture(userId) {
  requireLocalTogetherDatabase();
  if (!/^[a-f0-9-]{36}$/i.test(userId))
    throw new Error("Invalid fixture actor");
  const id = randomUUID(),
    application = randomUUID();
  sql(`begin;
    insert into app_private.portal_applications(id,event_id,applicant_user_id,review_status,requested_world_id,private_draft_data)
    select '${application}',event_id,'${userId}','approved',world_id,'{"fixture":true,"contactName":"Lotte Test","phone":"0612345678"}' from app_private.portals where id='12000000-0000-0000-0000-000000000001';
    insert into app_private.portals(id,event_id,application_id,world_id,name,description,intensity,approval_status,operation_status)
    select '${id}',event_id,'${application}',world_id,'De Lantaarnpoort','Fictieve poort voor lokale acceptatie.',1,'approved','scheduled' from app_private.portals where id='12000000-0000-0000-0000-000000000001';
    insert into app_private.portal_owners(portal_id,user_id,first_name,last_name) values('${id}','${userId}','Lotte','Test');
    insert into app_private.portal_private_locations(portal_id,street,house_number,postal_code,city,latitude,longitude,verified_at,verified_by)
    values('${id}','FICTIEF TESTADRES','1','0000AA','Teststad',52.1,4.27,now(),'${userId}');
    insert into app_private.portal_windows(portal_id,opens_at,closes_at,visit_minutes,max_concurrent_groups,max_children_per_visit)
    values('${id}','2026-10-31 17:00+01','2026-10-31 22:00+01',5,2,20);
    commit;`);
  return { id, application };
}
