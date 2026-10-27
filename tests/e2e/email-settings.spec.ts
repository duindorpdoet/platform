import { expect, test, type BrowserContext } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { sql, requireLocalTogetherDatabase } from "../../scripts/acceptance/together-fixtures.mjs";
import { prepareFixtureGuidance } from "./helpers/guidance";
const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
test.skip(process.env.SKIP_MAIL_TESTS === "true", "Explicit release mail-test exception");
test.skip(!url||!key||!process.env.MAIL_ADMIN_USER_IDS,"Requires isolated Auth/API and explicit system-mail admin fixture");
test.describe.configure({mode:"serial"});
async function login(context:BrowserContext,email="admin@example.invalid") {
 const client=createClient(url!,key!,{auth:{persistSession:false,autoRefreshToken:false}});
 const result=await client.auth.signInWithPassword({email,password:"local-test-only"});expect(result.error).toBeNull();await prepareFixtureGuidance(client);
 const name=`sb-${new URL(url!).hostname.split(".")[0]}-auth-token`,value=`base64-${Buffer.from(JSON.stringify(result.data.session)).toString("base64url")}`;
 await context.addCookies(Array.from({length:Math.ceil(value.length/3180)},(_,i)=>({name:value.length<=3180?name:`${name}.${i}`,value:value.slice(i*3180,(i+1)*3180),url:"https://127.0.0.1:3443",sameSite:"Lax" as const})));
}
test.beforeAll(()=>{
 requireLocalTogetherDatabase();
 sql("select api.worker_mail_bootstrap('staging','sender@example.invalid','De Poorten','reply@example.invalid');");
 sql("insert into app_private.event_capabilities(id,event_id,user_id,capability,granted_by) select 'f1000000-0000-4000-8000-000000000099',id,'b0000000-0000-0000-0000-000000000001','event_admin','f0000000-0000-0000-0000-000000000001' from app_private.events where slug='duindorp-halloween-2026' on conflict do nothing;");
});
test.afterAll(()=>{if(url&&key&&process.env.MAIL_ADMIN_USER_IDS)sql("delete from app_private.event_capabilities where id='f1000000-0000-4000-8000-000000000099';");});
test("direct mail settings link, actual draft save, non-sending failed checks and browser back",async({page,context})=>{
 await login(context);await page.goto("/admin?view=settings&settingsTab=email");
 const panel=page.getByRole("region",{name:"E-mail & koppelingen"});await expect(panel).toBeVisible();await expect(panel).toContainText("staging");await expect(panel).toContainText("SendGrid · migratie");
 await expect(panel).toContainText("RESEND_API_KEY: ontbreekt");await expect(panel).toContainText("Nog geen geldige events ontvangen");
 await panel.getByLabel("Afzendernaam",{exact:true}).fill("De Poorten lokale regressie");await panel.getByLabel("Afzenderadres",{exact:true}).fill("sender@example.invalid");await panel.getByLabel("Antwoordadres",{exact:true}).fill("reply@example.invalid");
 await panel.getByRole("button",{name:"Concept opslaan",exact:true}).click();await expect(panel.getByRole("status")).toContainText("Concept opgeslagen");
 expect(sql("select c.provider from app_private.mail_config_heads h join app_private.mail_config_versions c on c.id=h.active_id where h.environment='staging'")).toBe("sendgrid");
 await panel.getByRole("button",{name:"Controle uitvoeren zonder verzending",exact:true}).click();await expect(panel.getByRole("status")).toContainText("Controle nog niet geslaagd");
 await expect(panel.getByRole("button",{name:"Resend activeren",exact:true})).toBeDisabled();await expect(panel.getByRole("button",{name:"Testmail voorbereiden",exact:true})).toBeDisabled();
 expect(sql("select count(*) from app_private.email_outbox where message_type='mail_provider_test'")).toBe("0");
 await page.getByRole("navigation",{name:"Instellingen",exact:true}).getByRole("button",{name:"Evenementinstellingen",exact:true}).click();await expect(page).toHaveURL(/settingsTab=event/);await expect(panel).toHaveCount(0);
 await page.goBack();await expect(panel).toBeVisible();await expect(page).toHaveURL(/settingsTab=email/);
 await page.setViewportSize({width:390,height:844});await expect(panel.getByRole("button",{name:"Webhook-URL kopiëren",exact:true})).toBeVisible();
 const result=await page.request.get("/api/mail/settings");expect(result.status()).toBe(200);const body=await result.text();expect(body).not.toMatch(/whsec_|Bearer |local-test-only/);
});
test("an event_admin outside the runtime allowlist cannot inspect or change environment mail",async({page,context})=>{
 await login(context,"parent-b@example.invalid");await page.goto("/admin?view=settings&settingsTab=email");
 await expect(page.getByRole("region",{name:"E-mail & koppelingen"}).getByRole("alert")).toContainText("omgevingsbrede mailbeheerrechten");
 const response=await page.request.post("/api/mail/settings",{headers:{origin:"https://127.0.0.1:3443"},data:{command:"activate",expectedRevision:1,confirmed:true}});expect(response.status()).toBe(403);
});
