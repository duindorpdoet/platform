export function registrationActivationReturnPath(token: string) {
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error("INVALID_INVITATION");
  return `/uitnodiging/inschrijving/${token}?verified=1`;
}

export function registrationActivationMessage(code?: string) {
  switch (code) {
    case "INVITATION_EXPIRED":
      return "Deze uitnodiging is verlopen. Log in met het uitgenodigde e-mailadres en vraag hieronder een nieuwe uitnodiging aan. Jullie inschrijving en kinderen blijven bewaard.";
    case "FRESH_LOGIN_OR_EXPLICIT_CLAIM_REQUIRED":
      return "Je was al eerder ingelogd. Bevestig hieronder zelf dat je deze inschrijving wilt activeren, of log opnieuw in met het uitgenodigde e-mailadres.";
    case "REGISTRATION_ALREADY_EXISTS":
      return "Bij dit account bestaat al een inschrijving voor deze avond. Neem contact op met de organisatie om de juiste inschrijving te laten controleren.";
    default:
      return "Deze uitnodiging kon niet worden bevestigd. Gebruik het uitgenodigde e-mailadres en de nieuwste uitnodiging. De organisatie kan een verkeerd adres corrigeren.";
  }
}
