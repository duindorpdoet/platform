# Aanvullende lokale browserproef

Dit bewijs betreft uitsluitend de lokale productiebuild `Ok5RjR2fex_g9bgq4d5YE` met applicatiebron `090773a0a15a49316128e08004e026f1541c6e04`. De echte lokale GoTrue-, PostgreSQL- en browserstromen slagen voor vijftien controles. Dit is geen uitvoering op de gepubliceerde stagingomgeving.

[report.json](report.json) bevat de individuele controles, zeven screenshots, bronhashen, geslaagde cleanup en behoudsvergelijkingen. [cleanup-fault-proof.json](cleanup-fault-proof.json) beschrijft twee werkelijk geïnjecteerde fouten en het gecontroleerde herstel van uitsluitend de eigen testscope. [manifest.json](manifest.json) bewaart de oorspronkelijke uitvoeringsmetadata; de daarin genoemde `evidence/...`-paden verwijzen naar de oorspronkelijke tijdelijke werkmap. Het actuele rapport en de screenshots zijn hier plat overgenomen zonder hun inhoud te wijzigen.

[runner-source.zip](runner-source.zip) bevat uitsluitend de vijf beoordeelde testbronbestanden en de uitvoerinstructie, zonder credentials, omgevingsbestand of sessies. Zes uitvoergrenzen en een onafhankelijke bronreview zijn geslaagd. De runner weigert hosted uitvoering zonder de vereiste configuratie en expliciete doelbinding. Die credentialcontext was voor deze aanvullende proef niet beschikbaar; er is geen nieuwe workflow of alternatieve credentialroute gemaakt.

Geen OTP, externe PSP-betaling, mail-/pushbezorging, fysieke camera of hardware is hiermee bewezen. Twee onafhankelijke browsercontexts zijn geen twee fysieke telefoons.
