import Foundation

enum Context {
    static let birth: Set<String> = ["born", "bear", "dob", "birth", "birthday", "birthdate"]
    static let name: Set<String> = ["called", "named", "mr", "mrs", "ms", "dr", "contact", "owner", "customer", "patient", "employee", "its", "it's", "im", "i'm", "with", "w", "spoke", "ask", "tell", "cc"]
    // A mark is part of its word: Thai and Devanagari write vowels as marks on a letter ("บัตร").
    private static let word = TextPattern("\\p{L}[\\p{L}\\p{M}]*(?:['’]\\p{L}[\\p{L}\\p{M}]*)?")
    static func before(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        Set(words(before: range.lowerBound, in: text, limit: limit).map { $0.lowercased() })
    }
    static func after(_ range: Range<Int>, in text: String, limit: Int) -> Set<String> {
        Set(words(after: range.upperBound, in: text, limit: limit).map { $0.lowercased() })
    }
    // Reads a window that doubles until it holds more words than needed, so a
    // word cut by the window edge is never among those returned; scanning the
    // whole prefix or suffix instead makes long texts quadratic.
    static func words(before end: Int, in text: String, limit: Int, pattern: TextPattern = word) -> [String] {
        var width = 64
        while true {
            let start = max(0, end - width)
            let found = wordsIn(start..<end, of: text, pattern: pattern)
            if start == 0 || found.count > limit { return Array(found.suffix(limit)) }
            width *= 2
        }
    }
    static func words(after start: Int, in text: String, limit: Int, pattern: TextPattern = word) -> [String] {
        let length = (text as NSString).length
        var width = 64
        while true {
            let end = min(length, start + width)
            let found = wordsIn(start..<end, of: text, pattern: pattern)
            if end == length || found.count > limit { return Array(found.prefix(limit)) }
            width *= 2
        }
    }
    private static func wordsIn(_ range: Range<Int>, of text: String, pattern: TextPattern) -> [String] {
        let window = TextRanges.substring(text, range)
        return TextRanges.matches(pattern, in: window).map { TextRanges.substring(window, $0.range.location..<NSMaxRange($0.range)) }
    }
    static func enhanced(_ base: Double, words: Set<String>, range: Range<Int>, text: String) -> Double {
        before(range, in: text, limit: 5).isDisjoint(with: words) ? base : min(1, max(0.4, base + 0.35))
    }
}

public enum KeyHints {
    private static let groups: [(String, String)] = [
        ("name nm fullname contactname customername displayname ownername managername authorname reportername assigneename requestername sendername recipientname holdername cardholder cardholdername accountholder accountholdername patientname employeename legalname callername nameoncard nameonaccount payeename beneficiaryname billingname shippingname insuredname guarantorname subscribername policyholdername embossname embossedname chosenname debtorname creditorname receivername originatorname matchedname nameinenglish namelatin aka akas alsoknownas akaname associates nombrecompleto nomecompleto nameline1 nameline2 embossline1 originalscript nativescript namenative nativename localname namelocal nameoriginalscript", "PERSON"),
        ("firstname givenname middlename fname forename preferredname namefirst namemiddle namegiven forenames firstnames nombre nombres primernombre segundonombre prenom prenoms vorname vornamen nome primeironome", "FIRST_NAME"),
        ("lastname surname familyname lname maidenname namelast namefamily apellido apellidos apellidopaterno apellidomaterno primerapellido segundoapellido nom nomdefamille nomdusage nachname familienname cognome sobrenome", "LAST_NAME"),
        ("email emailaddress emailaddr mail", "EMAIL_ADDRESS"),
        ("phone phonenumber mobile cell telephone tel ph fax mobilenumber mobilephone cellphone cellnumber phoneno telno telephonenumber contactnumber msisdn nationalformat internationalformat e164", "PHONE_NUMBER"),
        ("ssn socialsecuritynumber socialsecurity ssnnumber", "US_SSN"),
        ("address streetaddress street addressline1 addressline2 addressline line1 line2 addr address1 street1 addr1 streetline1 street2 address2 addr2 streetline2 addressline3 line3 address3 addr3 street3 extendedaddress streetaddress2 aptsuite apartmentnumber aptnumber suitenumber unitnumber flatnumber unit apt apartment housenumber housenum houseno primarynumber housename flat flatno buildingnumber buildingno streetnumber streetnum streetno civicnumber premisenumber streetname thoroughfare buildingname formattedaddress fulladdress physicaladdress mailingaddress homeaddress residentialaddress billingaddress shippingaddress addressupdates addresshistory", "ADDRESS"),
        // The same fields as forms in other languages label them, written without their accents.
        ("geboortedatum geburtsdatum datedenaissance datenaissance fechadenacimiento fechanacimiento fechanac fechadenac datadinascita datanascita fodelsedatum datadenascimento datanascimento datanasc fodselsdato ngaysinh dogumtarihi dataurodzenia datumnarozeni datumnarodenia syntymaaika szuletesidatum tanggallahir tarikhlahir naissance datenaiss dtnaissance nascimento dtnascimento dtnasc nacimiento fnacimiento fecnac nascita gebdatum gebdat geboren geboorte fodd fodt narozeni urodzenia datanasterii datumrodenja datumrojstva synniaeg gimimodata dogum dogumgunu dogumyili namsinh sinhngay", "DATE_OF_BIRTH"),
        ("isim imie imiona voornaam voornamen fornamn fornavn etunimi prenume", "FIRST_NAME"),
        ("soyad soyadi soyisim soyismi kizliksoyadi nazwisko achternaam geslachtsnaam efternamn etternavn efternavn sukunimi apelido", "LAST_NAME"),
        ("hoten naam adsoyad adisoyadi isimsoyisim nama namalengkap imienazwisko volledigenaam nomcomplet", "PERSON"),
        ("diachi adres adresse direccion domicilio indirizzo residenza endereco morada anschrift wohnadresse adresa alamat ikametadresi", "ADDRESS"),
        ("straat strasse calle ulica", "ADDRESS"),
        ("noisinh dogumyeri geburtsort geboorteplaats lieudenaissance lieunaissance luogodinascita luogonascita lugardenacimiento lugarnacimiento localdenascimento localnascimento fodelseort paisnacimiento paisdenacimiento ciudadnacimiento ciudaddenacimiento provincianacimiento paesenascita paesedinascita cittanascita cittadinascita comunenascita comunedinascita provincianascita cidadenascimento cidadedenascimento paisnascimento paisdenascimento estadonascimento ufnascimento municipionascimento naturalidade villenaissance villedenaissance paysnaissance paysdenaissance communenaissance geburtsland geboorteland dogumili", "LOCATION"),
        ("ciudad cidade citta ville stadt plaats woonplaats wohnort miasto miejscowosc municipio comune localidad localita sehir ilce mahalle", "LOCATION"),
        ("codepostal codigopostal codicepostale postnummer postnr plz postleitzahl postakodu kodpocztowy", "POSTAL_CODE"),
        ("telefon telefono telefone telefoon telefonnummer telefoonnummer celular cellulare movil gsm ceptelefonu dienthoai sodienthoai tlf tfno", "PHONE_NUMBER"),
        ("eposta courriel correo correoelectronico epost epostadress", "EMAIL_ADDRESS"),
        ("passwort wachtwoord motdepasse contrasena senha losenord kennwort veiligheidscode creditcardveiligheidscode beveiligingscode sicherheitscode kartensicherheitscode kartenprufnummer prufnummer codedesecurite cryptogramme cryptogrammevisuel codigodeseguridad codicedisicurezza sakerhetskod kreditkortssakerhetskod codigodeseguranca pincode pinnummer pinkod pinkode codigopin codicepin codepin pinnumber accountpin cardpin atmpin currentpin newpin", "SECRET"),
        ("gebruikersnaam benutzername nomdutilisateur nombredeusuario nomeutente anvandarnamn nomedeusuario", "USERNAME"),
        // A fingerprint's, a face's or an iris's enrolment is its person's.
        ("biometricid biometricidentifier biometricnumber biometrictemplateid biometricref biometricreference", "ID_NUMBER"),
        ("licenceplate licenseplatenumber kenteken kennzeichen immatriculation plaquedimmatriculation matricula placa targa registreringsnummer", "ID_NUMBER"),
        ("dob dateofbirth birthdate birthday birthyear yearofbirth yob birthmonth monthofbirth dobmonth dobday dayofbirth dobyear birth birthdetails birthinfo", "DATE_OF_BIRTH"),
        // Where someone was born is theirs as their address is.
        // A card's number, whole or masked ("999911XXXXXX1234").
        ("cardnumber creditcardnumber debitcardnumber ccnumber cardno primaryaccountnumber pan", "CREDIT_CARD"),
        ("cityofbirth placeofbirth birthplace birthcity townofbirth municipalityofbirth pob countryofbirthcity birthfacility birthhospital hospitalofbirth", "LOCATION"),
        // A civil registry's record of a birth names the state and the town it was registered in ("registrationEntity", "registrationEntity2").
        ("birthregion birthstate stateofbirth provinceofbirth regionofbirth birthstatekey birthstatecode registrationentity", "REGION"),
        // A passport's or ID card's machine-readable zone, one line or all of them.
        ("mrz mrz1 mrz2 mrz3 mrzline mrzline1 mrzline2 mrzline3 mrzlines mrzcode machinereadablezone", "MRZ"),
        ("age ageyears currentage", "AGE"),
        // A card's expiry, whole or in parts; a bare "expiry" is one only on a card or a document (see `expiry`).
        ("cardexpiry cardexpirydate cardexpiration cardexpirationdate cardexpdate cardexpires expmonth expyear expiryday expirymonth expiryyear expirationmonth expirationyear cardexpmonth cardexpyear cardexpirymonth cardexpiryyear expirymm expiryyy expiryyyyy", "EXPIRY_DATE"),
        ("initials nameinitials monogram middleinitial", "INITIALS"),
        ("latitude lat geolat", "LATITUDE"),
        ("longitude lng lon long geolng geolon", "LONGITUDE"),
        ("coordinates coordinate coords latlng latlong latlon geolocation geopoint geocoordinates", "COORDINATES"),
        ("ip ipaddress ipaddr clientip remoteip remoteaddr xforwardedfor", "IP_ADDRESS"),
        ("city town locality municipality municipalityname cityname townname suburb district neighborhood neighbourhood village hamlet sublocality dependentlocality county", "LOCATION"),
        ("zip zipcode postcode postalcode zip5 zipplus4 postal postalzip", "POSTAL_CODE"),
        ("state stateprovince stateorprovince province provincestate region addressregion administrativearea administrativearealevel1 statecode provincecode regioncode stateabbr stateabbreviation countrysubdivision majoradmindivision administrativedistrictlevel1 subdivision prefecture canton", "REGION"),
        ("password passwd pwd passphrase secret clientsecret apisecret apikey accesskey secretkey privatekey token accesstoken refreshtoken idtoken authtoken sessiontoken bearertoken authorization cookie sessionid otp credential credentials cvv cvc cvv2 securitycode pin secretanswer securityanswer memorableword memorableanswer", "SECRET"),
        ("username login handle screenname nickname", "USERNAME"),
        // A ZIP code's four extra digits in a field of their own name a block or a building.
        ("zip4 plus4 zipplus4code zipext zipextension zipcodeext zipcodeextension zipaddon", "ID_NUMBER"),
        ("nationalid nationalidnumber nationalidentifier nationalinsurancenumber nino personalnumber personalidnumber personnummer idnumber identitynumber identitycard idcard idcardnumber governmentid identitydocument passport passportnumber passportno passportid taxid taxnumber taxpayerid tin sin socialinsurancenumber driverlicense driverslicense driverlicensenumber dlnumber dlno dlnum licensenumber driverlicence driverslicence drivinglicence drivinglicense licencenumber driverlicencenumber nif nie dni cpf curp pesel bsn aadhaar documentnumber accountnumber bankaccountnumber acctnumber accountno acctno acctnum routingnumber sortcode ein creditfilenumber cpfnumber nis nisnumber cic electorkey electornumber docnumber documentno licenseplate platenumber identificationnumber idno photoid photoidnumber imsi ocr mxine ine", "ID_NUMBER")
    ]
    /// Every key name and the kind it hints, the registry's identifiers' keys among them (see `Recognizers`).
    private static let hints = Dictionary(uniqueKeysWithValues: groups.flatMap { names, entity in
        names.split(separator: " ").map { (String($0), entity) }
    }).merging(Recognizers.keyNames) { listed, _ in listed }
    // Real keys qualify the field ("db_password", "webhook_secret"), so the last
    // word decides. "max_tokens" or "sort_key" name no secret and stay as they are.
    private static let secretLast: Set<String> = ["password", "passwd", "pwd", "passphrase", "secret", "token", "credential", "credentials", "cvv", "cvc", "otp", "passwort", "wachtwoord", "senha", "losenord", "kennwort", "contrasena"]
    private static let secretPairs: Set<String> = ["apikey", "accesskey", "secretkey", "privatekey", "encryptionkey", "masterkey", "signingkey", "sshkey", "licensekey", "clientkey", "authkey", "passwordhash", "otpcode", "securitycode", "verificationcode", "recoverycode", "recoverycodes", "backupcodes", "sessionid", "sessioncookie", "authcookie"]
    public static func hint(_ key: String?) -> String? {
        guard var key, !key.isEmpty else { return nil }
        // "Código postal", "Födelsedatum": a key's accents dropped, as the names above are written.
        // A dotless "ı" has no accent to drop: "Soyadı" is "soyadi".
        if key.utf8.contains(where: { $0 >= 0x80 }) { key = key.replacingOccurrences(of: "ı", with: "i").folding(options: .diacriticInsensitive, locale: nil) }
        var compact = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if compact.hasSuffix("field"), compact.count > 5, case let inner = words(key).joined(), inner.count < compact.count { compact = inner }
        if let exact = hints[compact] { return exact }
        // Lists of one field ("names", "phone_numbers", "email_addresses") hint like the field.
        if let singular = singular(compact), !unpluralised.contains(singular), let plural = hints[singular] { return plural }
        // "ssn_last4", "card.last4", "last_four_digits": the end of a number, not a count.
        if compact.contains("last4") || compact.contains("lastfour") || compact == "ssn4" || compact == "mask" || compact == "accountmask" { return "LAST_DIGITS" }
        // "last_digits", "id_mask", "account_number_suffix": the end of a number shown alone.
        if ["lastdigits", "cardlastdigits"].contains(compact) || compact.hasSuffix("mask") && compact.count > 4 && ["idmask", "ssnmask", "tinmask", "taxidmask", "cardmask", "panmask", "numbermask"].contains(where: compact.hasSuffix)
            || compact.hasSuffix("numbersuffix") { return "LAST_DIGITS" }
        // "ssn_masked": "***-**-7784" still shows the real last digits.
        if compact.contains("masked") || compact.contains("redacted") || compact.contains("obfuscated") { return words(key).contains(where: { ["ssn", "card", "pan", "phone", "account", "acct", "number", "tin", "taxid"].contains($0) }) ? "LAST_DIGITS" : nil }
        // A field written again under its number ("email2", "registrationEntity2") is the field.
        if compact.last?.isNumber == true, case let bare = String(compact.reversed().drop(while: \.isNumber).reversed()), bare.count >= 3, let field = hints[bare] { return field }
        let parts = words(key)
        guard let last = parts.last else { return nil }
        if let either = alternatives(parts), let field = hint(either[0]), hint(either[1]) == field { return field }
        if secretLast.contains(last) || parts.count >= 2 && secretPairs.contains(parts[parts.count - 2] + last) { return "SECRET" }
        // A contact field qualified after it ("phoneHome", "phone_cell", "email_work") is the field.
        if parts.count == 2, let field = hints[parts[0]], ["PHONE_NUMBER", "EMAIL_ADDRESS"].contains(field),
           phoneQualifiers.contains(parts[1]) || addressQualifiers.contains(parts[1]) || ["home", "work", "cell", "mobile", "office", "fax", "main", "other"].contains(parts[1]) { return field }
        // A person's value hashed ("email_md5", "username_sha256") is theirs as the value is (see `isDigest`).
        if parts.count >= 2, digestWords.contains(last), let field = hint(parts.dropLast().joined(separator: "_")), digestKinds.contains(field) { return field }
        // A field written for display holds the field: "dob_display", "phone_formatted".
        if parts.count >= 2, displayWords.contains(last), let field = hint(parts.dropLast().joined(separator: "_")) { return field }
        // A birth date written in parts holds them: "dob_parts": {"day": …}, "dateOfBirthComponents".
        if parts.count >= 2, ["parts", "components", "breakdown", "split"].contains(last), hint(parts.dropLast().joined(separator: "_")) == "DATE_OF_BIRTH" { return "DATE_OF_BIRTH" }
        if let relative = relativesName(parts) { return relative }
        if let field = qualified(parts) { return field }
        // A field's name abbreviated ("natId", "doc_no", "birth_dt") hints as the field written out.
        let expanded = parts.map { abbreviations[$0] ?? $0 }
        return expanded != parts ? hints[expanded.joined()] : nil
    }
    /// The two fields a key offers a choice of ("houseNumberOrName", "email_or_phone"), the second
    /// written short where it shares the first's opening words: "house number or [house] name".
    static func alternatives(_ parts: [String]) -> [String]? {
        guard parts.count >= 3, parts.count <= 6, let or = parts.firstIndex(of: "or"), or > 0, or < parts.count - 1 else { return nil }
        let left = Array(parts[..<or]), right = Array(parts[(or + 1)...])
        let shared = Array(left.prefix(max(0, left.count - right.count))) + right
        let second = hints[shared.joined()] != nil ? shared : right
        return [left.joined(separator: "_"), second.joined(separator: "_")]
    }
    private static let abbreviations: [String: String] = ["nat": "national", "natl": "national", "doc": "document", "no": "number", "nr": "number", "num": "number", "nbr": "number", "dt": "date"]
    /// A relative's name, in either order and in other languages ("mother_name", "mothersMaidenName",
    /// "nome_mae", "pita_ka_naam"): a person's name, the record's own person's never (see `namesARole`).
    /// A bare word for a name ("nome", "naam") is the relative's whole name.
    private static func relativesName(_ parts: [String]) -> String? {
        guard parts.count >= 2, parts.count <= 6, parts.contains(where: relatives.contains) else { return nil }
        let rest = parts.filter { !relatives.contains($0) && !linkingWords.contains($0) }
        guard !rest.isEmpty, rest.count < parts.count else { return nil }
        if bareNames.contains(rest.joined()) { return "PERSON" }
        guard let field = hint(rest.joined(separator: "_")), ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(field) else { return nil }
        return field
    }
    /// A word for a name a relative's key closes with ("babaAdi", "imie_ojca"): their whole name.
    private static let bareNames: Set<String> = ["name", "nm", "nome", "nombre", "nom", "naam", "names", "nomes", "nombres", "ad", "adi", "isim", "imie"]
    private static let relatives: Set<String> = ["mother", "mothers", "father", "fathers", "mom", "moms", "dad", "dads", "parent", "parents", "spouse", "spouses", "husband", "husbands", "wife", "wifes",
                                                 "mae", "pai", "madre", "padre", "mere", "pere", "mutter", "vater", "moeder", "vader", "pita", "mata", "pati", "patni", "anne", "baba", "matki", "ojca"]
    private static let linkingWords: Set<String> = ["of", "ka", "ki", "ke", "de", "do", "da", "del", "la", "du", "des", "der", "van", "von", "s"]
    /// A field named with a qualifier in front ("billing_email", "home_phone",
    /// "applicant_dob") hints like the field. Only fields that mean the same
    /// whatever qualifies them: a "company_name" is no person and a "mac_address"
    /// no street, so "name" and "address" count only after a personal qualifier.
    private static func qualified(_ parts: [String]) -> String? {
        // A field name runs a few words; a longer "key" is text, and trying every split of it costs its square.
        guard parts.count >= 2, parts.count <= 8 else { return nil }
        for start in 1..<parts.count {
            // "num_family_names", "has_email", "is_phone_verified" describe the field; they don't hold it.
            if parts[..<start].contains(where: countWords.contains) { return nil }
            let suffix = parts[start...].joined()
            let field = hints[suffix] != nil ? suffix : singular(suffix).flatMap { hints[$0] != nil && !unpluralised.contains($0) ? $0 : nil }
            guard let field, let entity = hints[field] else { continue }
            let qualifier = parts[start - 1]
            switch field {
            // "primary_name" and "secondary_name": the first and the second person a record names.
            // "altName", "nativeName", "latin_name", "kanjiName": the name written another way.
            case "name", "nm": if people.contains(qualifier) || roles.contains(qualifier) || ["primary", "secondary"].contains(qualifier) || writtenQualifiers.contains(qualifier) { return entity }
            case "address", "addr": if addressQualifiers.contains(qualifier) || writtenQualifiers.contains(qualifier) && qualifier != "local" { return entity }
            // "primary_mobile", "customer_cell": a phone, as "is_mobile" and "mobile_app" are not.
            case "mobile", "cell", "tel", "ph": if people.contains(qualifier) || roles.contains(qualifier) || addressQualifiers.contains(qualifier) || phoneQualifiers.contains(qualifier) { return entity }
            case "mail", "handle", "login", "pin", "otp", "cookie", "authorization", "passport", "credential", "credentials", "secret", "token": continue
            default: return entity
            }
        }
        return nil
    }
    private static let writtenQualifiers: Set<String> = ["alt", "alternate", "alternative", "other", "native", "local", "latin", "original", "english", "romanized", "romanised", "transliterated", "translit",
                                                         "kanji", "kana", "katakana", "hiragana", "romaji", "hangul", "pinyin", "cyrillic", "arabic", "greek", "hebrew", "chinese", "japanese", "korean"]
    private static let digestWords: Set<String> = ["md5", "sha1", "sha256", "sha512", "hash", "hashed", "digest"]
    static let digestKinds: Set<String> = ["EMAIL_ADDRESS", "PHONE_NUMBER", "USERNAME", "PERSON", "FIRST_NAME", "LAST_NAME", "US_SSN", "ID_NUMBER", "ADDRESS", "DATE_OF_BIRTH", "IP_ADDRESS", "CREDIT_CARD"]
    private static let digest = TextPattern(#"^(?:[0-9a-f]{32}|[0-9a-f]{40}|[0-9a-f]{64}|[0-9a-f]{128}|[0-9A-F]{32}|[0-9A-F]{40}|[0-9A-F]{64})$"#)
    /// A hash's hex digest ("5d2a9e0f7c13b48e6a0f9d21c7b3e845"): under a person's key, their value hashed, which looks them up as well as the value.
    static func isDigest(_ value: String) -> Bool { !TextRanges.matches(digest, in: value).isEmpty }
    private static let displayWords: Set<String> = ["display", "displayed", "formatted", "full", "pretty", "readable", "text", "string", "str", "iso",
                                                      // A field as a document writes it in a script or a language: "last_name_en", "firstNameLatin".
                                                      "en", "eng", "english", "latin", "local", "native", "translit", "transliterated", "romanized", "romanised", "ascii", "original",
                                                      // …by the script's or the language's code or name ("nameKo", "nameLatn", "addressJP", "nameKanji"), or as an alternative ("name_alt").
                                                      "latn", "cyrl", "arab", "grek", "hebr", "deva", "hans", "hant", "jpan", "kore", "hira", "hrkt", "thai",
                                                      "ko", "kr", "kor", "ar", "ara", "ru", "rus", "ja", "jp", "jpn", "zh", "cn", "chn", "zho", "tw", "hk", "he", "heb", "el", "gr", "ell", "hi", "hin", "th", "tha",
                                                      "vi", "vn", "vie", "fa", "ur", "bn", "ta", "uk", "ua", "ukr", "bg", "sr", "hy", "ka", "fr", "de", "es", "pt", "nl", "pl", "tr", "gb", "us",
                                                      "kanji", "kana", "katakana", "hiragana", "furigana", "romaji", "hangul", "pinyin", "roman", "romanization", "romanisation", "transliteration",
                                                      "cyrillic", "arabic", "greek", "hebrew", "chinese", "japanese", "korean", "devanagari", "hindi", "russian", "alt", "alternate", "alternative", "other"]
    private static let phoneQualifiers: Set<String> = ["secondary", "alternate", "alt", "other", "personal", "private", "business", "emergency", "direct", "day", "evening", "night"]
    private static let countWords: Set<String> = ["num", "number", "count", "counts", "total", "has", "is", "max", "min", "avg", "sum", "qty", "len", "length", "size", "match", "matches", "score", "verified", "valid", "exists", "present", "changed", "updated", "type", "status", "source", "flag", "enabled", "required", "last4", "hash", "hashed", "format", "domain", "risk"]
    static let addressQualifiers: Set<String> = ["home", "mailing", "billing", "shipping", "residential", "street", "physical", "postal", "current", "previous", "permanent", "primary", "customer", "user", "applicant", "contact", "work", "residence", "legal", "delivery", "registered"]
    // Plurals that name something else: spreadsheet "cells", event "logins".
    private static let unpluralised: Set<String> = ["cell", "tel", "mail", "handle", "login"]
    private static func singular(_ compact: String) -> String? {
        if compact.hasSuffix("ies") { return String(compact.dropLast(3)) + "y" }
        if compact.hasSuffix("sses") { return String(compact.dropLast(2)) }
        if compact.hasSuffix("s") && !compact.hasSuffix("ss") { return String(compact.dropLast()) }
        return nil
    }
    /// The key a value is read under, given the key its container is read under.
    /// A key naming nothing takes its parent's meaning when anything under a
    /// secret is secret ("credentials": {"user": …}) or it only holds the parent's
    /// value ("id_number": {"value": …}, "emails": [{"data": …}]). Parts of a
    /// field are read as the part: "name": {"first": …}, "phones": [{"number": …}],
    /// "emails": [{"address": …}], "address": {"line": […]}, "dob": {"year": …}.
    /// The key an object or a list is read under: as `resolve`, but a secret's
    /// map's meaning reaches every map in it ("credentials": {"primary": {"value": …}}),
    /// but a list's record ("credentials": [{"parts": […]}], an ID document's) is its own.
    static func resolveContainer(_ key: String?, parent: String?, listed: Bool = false) -> String? {
        hint(parent) == "SECRET" && hint(key) == nil && listed && !secretParts.contains(words(key).joined()) ? key : resolve(key, parent: parent)
    }
    /// `listed`: the value sits in a record of a list ("credentials": [{…}]), whose fields
    /// describe a document or a check, and only a credential's own parts are secret there,
    /// or a `value` written as a token is ("primary": "t7Pq9mN2sV4bX6kL").
    static func resolve(_ key: String?, parent: String?, listed: Bool = false, value: String? = nil) -> String? {
        // An identity document's own number: "document": {"number": …}, "idDocs": [{"number": …}].
        // A driver's licence by its initials: "dl": {"number": …}.
        if hint(key) == nil, documentNumbers.contains(words(key).joined()), let last = words(parent).last, identityDocuments.contains(last) || ["dl", "dls"].contains(last) { return "document_number" }
        // A name's parts under its letter ("N": {"F": …, "L": …}) are read as under "name".
        guard let parentHint = hint(parent) ?? (words(parent) == ["n"] && shortNameParts[words(key).joined()] != nil ? "PERSON" : nil) else { return key }
        let own = hint(key)
        let compact = words(key).joined()
        switch parentHint {
        // A credential's own parts ("credentials": {"user": …, "primary": …, "webhook": …}); never what a
        // list of authorizations or of captured credentials describes them with ("amount", "category", "type").
        case "SECRET" where own == nil && listed:
            let token = value.map(isTokenShaped) == true && !describing.contains(compact) && !isStructural(key)
            return secretParts.contains(compact) || token ? parent : key
        case "SECRET" where own == nil && (["hash", "salt", "digest", "signature", "fingerprint"].contains(compact) || !describing.contains(compact) && !describing.contains(words(key).last ?? "") && !isStructural(key)): return parent
        case "PERSON":
            if ["first", "given", "givennames", "forenames", "firstnames"].contains(compact) { return "first_name" }
            if ["middle", "middlenames", "middles"].contains(compact) { return "middle_name" }
            if ["last", "family", "familynames", "lastnames", "surnames"].contains(compact) { return "last_name" }
            // A name's parts include the surname someone was born with: "names": {"family": …, "maiden": …}, a surname of its own.
            if ["maiden", "birth", "birthname"].contains(compact) { return "maiden_name" }
            if ["full", "display", "formatted", "text"].contains(compact) { return "full_name" }
            if let part = shortNameParts[compact] { return part }
        case "PHONE_NUMBER" where ["number", "digits", "e164", "national", "nationalnumber", "international", "internationalnumber", "formatted", "raw", "full"].contains(compact): return parent
        case "EMAIL_ADDRESS" where ["address", "addr"].contains(compact): return parent
        case "ADDRESS" where ["line", "lines", "text", "formatted", "full"].contains(compact): return parent
        // A document's own number under a bare key: "passport": {"number": …}, "national_ids": [{"number": …}].
        case "ID_NUMBER" where own == nil && documentNumbers.contains(compact), "US_SSN" where own == nil && documentNumbers.contains(compact): return parent
        // Read as the part it is, so its stand-in is that part of the stand-in date: "dob": {"month": 3} is a "birth_month".
        case "DATE_OF_BIRTH" where ["year", "month", "day", "yyyy", "mm", "dd"].contains(compact):
            return ["year": "birth_year", "yyyy": "birth_year", "month": "birth_month", "mm": "birth_month", "day": "day_of_birth", "dd": "day_of_birth"][compact]
        // A birth's record holds its date: "birth": [{"date": {"year": …}}].
        // "Date" in a record's other languages: "naissance": {"date": …}, "dogum": {"tarih": …}, "ngay_sinh": {"ngay": …}.
        case "DATE_OF_BIRTH" where ["date", "fulldate", "dates", "data", "fecha", "datum", "tarih", "ngay", "dato", "datadinascita"].contains(compact): return parent
        // A card's expiry in parts: "expiration": {"month": 1, "year": 28}.
        case "EXPIRY_DATE" where ["month", "mm"].contains(compact): return "expiry_month"
        case "EXPIRY_DATE" where ["year", "yy", "yyyy"].contains(compact): return "expiry_year"
        case "EXPIRY_DATE" where ["day", "dd"].contains(compact): return "expiry_day"
        default: break
        }
        // A field written in several scripts or forms holds it in each: "firstName": {"latin": …}, "dateOfBirth": {"originalString": …}.
        if own == nil, parentHint != "SECRET", writtenForms.contains(compact) { return parent }
        return own == nil && valueKeys.contains(compact) ? parent : key
    }
    private static let valueKeys: Set<String> = ["value", "data"]
    /// A name's parts by their letters, as a short-keyed payload writes them under the name.
    private static let shortNameParts: [String: String] = ["f": "first_name", "fn": "first_name", "g": "first_name", "m": "middle_name", "mn": "middle_name", "mi": "middle_name",
                                                           "l": "last_name", "ln": "last_name", "s": "last_name", "sn": "last_name"]
    /// The keys of a name's two parts written side by side in a record with no name of their own:
    /// "first"/"last", "fn"/"ln", "given"/"family", "first_nm"/"last_nm". Either alone may be a
    /// list's or a page's end, so only the pair, both holding a word or two of a name, reads as
    /// one person's first and last names. Keys the table already names are left to it.
    /// A part the table names beside it counts as its own ({"surname": …, "given": …}).
    ///
    /// A name written another way under a key of its own ("pinyin", "romaji", "kana",
    /// "transliteration") is the person's whole name, beside one of their names or
    /// under a person ("applicant": {"romaji": …}).
    static func nameParts(_ siblings: [(String, String)], parent: String? = nil) -> [String: String] {
        var found: [String: String] = [:]
        let named = siblings.compactMap { pair in hint(pair.0).flatMap { ["FIRST_NAME", "LAST_NAME"].contains($0) && namePartShaped(pair.1) ? $0.lowercased() : nil } }
        for (key, value) in siblings where hint(key) == nil {
            guard let part = namePartKey(key), namePartShaped(value) else { continue }
            found[key] = part
        }
        let parts = Set(found.values).union(named)
        if !(parts.contains("first_name") && parts.contains("last_name")) { found = [:] }
        let beside = siblings.contains { ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(hint($0.0) ?? "") && !namesARole($0.0) }
        if beside || isPersonsRecord(siblings: [], parent: parent) {
            for (key, value) in siblings where hint(key) == nil && transliterations.contains(words(key).joined()) && writtenAsAnyName(value) { found[key] = "full_name" }
        }
        return found
    }
    private static let transliterations: Set<String> = ["pinyin", "romaji", "kana", "kanji", "katakana", "hiragana", "furigana", "hangul", "latin", "romanized", "romanised", "romanization", "romanisation",
                                                        "transliteration", "transliterated", "translit", "transcription"]
    /// One to five words of letters in any script, as a name is written: no digit, no sentence's punctuation.
    private static func writtenAsAnyName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return (1...5).contains(trimmed.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).count) && trimmed.filter(\.isLetter).count >= 2
            && trimmed.allSatisfy { $0.isLetter || " \u{3000}'’-.,・·".contains($0) } && !isCommonValue(trimmed)
    }
    /// The part of a name a key names on its own, when a sibling names the other part (see `nameParts`).
    static func namePartKey(_ key: String?) -> String? {
        pairedNameParts[words(key).filter { !["name", "nm", "nme", "n"].contains($0) }.joined()]
    }
    /// A Turkish record's "ad" and "adi" are a first name beside a surname ("soyad"), and no advert's.
    private static let pairedNameParts: [String: String] = ["first": "first_name", "given": "first_name", "fn": "first_name", "fnm": "first_name", "gn": "first_name", "ad": "first_name", "adi": "first_name",
                                                            "middle": "middle_name", "mn": "middle_name",
                                                            "last": "last_name", "family": "last_name", "ln": "last_name", "lnm": "last_name", "sur": "last_name"]
    /// A word or two of a name, in any case: letters, an apostrophe or a hyphen, none of them an ordinary word or a weekday.
    private static func namePartShaped(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ")
        guard (1...3).contains(parts.count), trimmed.filter(\.isLetter).count >= 2, trimmed.allSatisfy({ $0.isLetter || " '’-.".contains($0) }),
              !isCommonValue(trimmed), !NameTagger.namesOrganisation(trimmed) else { return false }
        return trimmed.split(whereSeparator: { !$0.isLetter }).allSatisfy { part in
            let word = String(part)
            if NameShape.weekdays.contains(word.lowercased()) || NameShape.months.contains(word.lowercased()) { return false }
            return word.count < 2 || NameLists.isFirst(word) || NameLists.isSurname(word) || !NameLists.isWord(word)
        }
    }
    private static let writtenForms: Set<String> = ["latin", "cyrillic", "arabic", "greek", "hebrew", "chinese", "japanese", "korean", "kana", "kanji", "hangul", "thai", "native", "local", "localized", "localised",
                                                    "original", "originalstring", "originalvalue", "translit", "transliterated", "transliteration", "romanized", "romanised", "ascii", "english", "en", "raw", "rawvalue"]
    private static let objectReference = TextPattern(#"^[A-Z]{1,5}-[A-Za-z0-9]{5,40}$"#)
    /// A key's or a token's shape: long, one word, letters and digits, no link and no UUID.
    static func isTokenShaped(_ value: String) -> Bool {
        value.utf16.count >= 12 && !value.contains(where: \.isWhitespace) && !value.contains("://") && value.contains(where: \.isNumber) && value.contains(where: \.isLetter)
            && !RecordIDs.isUUID(value)
    }
    private static let secretParts: Set<String> = ["user", "username", "userid", "login", "pass", "passwd", "value", "data", "key", "secret", "pin", "hash", "salt", "bearer", "basic", "digest", "raw", "encoded"]
    private static let describing: Set<String> = ["amount", "category", "categories", "name", "description", "label", "title", "count", "total", "reason", "result", "outcome", "message",
                                                  "decision", "state", "enabled", "active", "mode", "environment", "env", "length", "last4", "lastfour", "expiration", "expirationdate", "provider", "source",
                                                  "merchant", "descriptor", "mcc", "approved", "declined", "captured", "pending", "response", "responsecode", "avs", "level", "purpose", "usage", "owner"]
    /// A template's slot in a sample, never a value: ":case_token", "{api_key}", "{{token}}", "<password>", "${SECRET}".
    /// A brace may be left open: a pattern in text stops before the closing one. A sample's
    /// "YOUR_API_KEY" is one too.
    private static let placeholder = TextPattern(#"^(?::[A-Za-z][\w.-]*|\$\{[A-Za-z][\w.-]*\}|\{\{?\s*[A-Za-z][\w.-]*\s*(?:\}\}?)?|<[A-Za-z][\w .-]*>|(?:YOUR|MY|INSERT|REPLACE)_[A-Z0-9_]+|(?:your|my)[_-][a-z0-9_-]+)$"#)
    private static let jsonLiterals: Set<String> = ["null", "true", "false", "nil", "none", "undefined"]
    private static let credentialCollections: Set<String> = ["credentials", "credential", "secrets", "authorizations", "authorization", "tokens", "keys"]
    /// A word a field's value often is ("pass", "string", "active"): a secret
    /// that is one is replaced where it was found, never in every other place.
    /// Whether a person key names someone in a role the record only mentions ("receiver_name",
    /// "emboss_name", "matched_name", "aka"), not the record's own person ("name", "last_name").
    /// A relative's name, or a maiden name, is someone else's too.
    static func namesARole(_ key: String?) -> Bool {
        let parts = words(key), compact = parts.joined()
        // One a flat key's qualifier names ("spouse_name", "mother_email") is a person of their own there (see `personPrefix`).
        if parts.contains(where: { relatives.contains($0) || $0 == "maiden" }), ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(hint(key) ?? ""), personPrefix(key) == nil { return true }
        return roleNames.contains(compact) || roleNames.contains(singular(compact) ?? "")
    }
    private static let roleNames: Set<String> = ["embossname", "embossedname", "debtorname", "creditorname", "receivername", "originatorname", "matchedname", "aka", "alsoknownas",
                                                 "sendername", "recipientname", "beneficiaryname", "payeename", "callername", "assigneename", "reportername", "requestername", "authorname", "managername"]
    /// Whether a key is a field's own name as the table writes it ("password", "first_name",
    /// "phone_numbers"), not one that only ends like one ("quillharbor_token").
    static func isFieldName(_ key: String) -> Bool {
        let compact = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return hints[compact] != nil || singular(compact).map { hints[$0] != nil } == true || Recognizers.fieldNames.contains(compact)
    }
    /// A key written with a value in it, an email's "@" or digits, not a field's plain name.
    static func holdsData(_ key: String) -> Bool { key.contains(where: { $0.isNumber || $0 == "@" }) }
    static func isCommonValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        return statusWords.contains(lower) || typeWords.contains(lower) || jsonLiterals.contains(lower)
    }
    private static let cardCodes: Set<String> = ["cvv", "cvc", "cvv2", "cvc2", "cvn", "csc", "securitycode", "cardsecuritycode", "pin", "pinnumber", "accountpin", "cardpin", "atmpin", "currentpin", "newpin",
                                                 "veiligheidscode", "creditcardveiligheidscode", "beveiligingscode", "sicherheitscode", "kartensicherheitscode", "kartenprufnummer", "prufnummer", "codedesecurite", "cryptogramme",
                                                 "cryptogrammevisuel", "codigodeseguridad", "codicedisicurezza", "sakerhetskod", "kreditkortssakerhetskod", "codigodeseguranca", "pincode", "pinnummer", "pinkod", "pinkode", "codigopin", "codicepin", "codepin"]
    /// What an object a "*_token" key may name instead of a credential: under any
    /// other qualifier ("access", "recovery", "invite") a token stays a secret.
    private static let referenceQualifiers: Set<String> = ["entity", "request", "evaluation", "application", "group", "account", "journey", "model", "counterparty",
                                                           "card", "list", "investigation", "append", "case", "document", "event", "review", "workflow", "alert",
                                                           "task", "note", "file", "report", "transaction", "payment", "customer", "person", "business", "version",
                                                           "batch", "job", "rule", "policy", "attachment", "decision", "screening", "watchlist", "error", "node", "event", "source"]
    static func isDocumentNumber(_ key: String) -> Bool { documentNumbers.contains(words(key).joined()) }
    /// Words a record's kind field writes for an identity document ("driver_license", "passport").
    static let documentKinds: Set<String> = ["license", "licence", "passport", "idcard", "identitycard", "permit", "visa", "nationalid", "residencepermit"]
    private static let documentNumbers: Set<String> = ["number", "no", "num", "nr", "numero", "documentnumber", "idnumber", "latin"]
    private static let identityDocuments: Set<String> = ["document", "documents", "doc", "docs", "iddoc", "iddocs", "iddocument", "iddocuments", "identitydocument", "identitydocuments"]
    /// One part of a date written in a field of its own.
    public enum DatePart: Sendable { case year, month, day }
    /// The part of a birth date a key names on its own: "birth_month",
    /// "monthOfBirth", "dob_day", "birth_year". A "birthday" is a whole date.
    static func datePart(_ key: String?) -> DatePart? {
        let parts = words(key), compact = parts.joined()
        // A card's expiry month and year ("exp_month": 6, "exp_year": 2029).
        if hint(key) == "EXPIRY_DATE" {
            if compact.contains("month") || parts.last == "mm" { return .month }
            if compact.contains("year") || ["yy", "yyyy"].contains(parts.last ?? "") { return .year }
            if parts.last == "day" || parts.last == "dd" { return .day }
            return nil
        }
        guard hint(key) == "DATE_OF_BIRTH" else { return nil }
        if compact.contains("month") || parts.last == "mm" { return .month }
        if compact.contains("year") || compact == "yob" || parts.last == "yyyy" { return .year }
        if parts.count >= 2 && parts.contains(where: { $0 == "day" || $0 == "dd" }) || ["dobday", "dayofbirth"].contains(compact) { return .day }
        return nil
    }
    /// An object that only wraps a field's value with notes about it
    /// (`{"value": …, "verified": true}`), and so is part of the record around it.
    static func isWrapper(_ keys: [String]) -> Bool {
        let compact = keys.map { words($0).joined() }
        return (1...4).contains(compact.count) && compact.contains(where: valueKeys.contains)
            && compact.allSatisfy { valueKeys.contains($0) || wrapperNotes.contains($0) }
    }
    private static let wrapperNotes: Set<String> = ["verified", "isverified", "confirmed", "type", "source", "status", "primary", "isprimary", "label", "updatedat", "confidence", "valid"]
    /// Keys whose sibling says what the value is: form fields, typed identifiers
    /// and FHIR contact points (`{"name": "ssn", "value": …}`, `{"system": "phone", "value": …}`).
    static let fieldValueKeys: Set<String> = ["value", "values", "data", "text", "val", "v", "answer", "response", "originalvalue", "extractedvalue", "expectedvalue", "actualvalue", "inputvalue", "submittedvalue", "providedvalue", "returnedvalue", "normalizedvalue"]
    static let fieldNameKeys: Set<String> = ["name", "key", "k", "field", "fieldname", "fieldid", "fieldkey", "id", "label", "type", "system", "attribute", "property", "question", "code",
        // "Type" in other languages, as a document's attribute names its kind (<Documento tipo="NIE">).
        "kind", "typ", "tipo", "tip", "tipe", "soort", "loai"]
    /// The field a record's value-holding key stands for, from its naming sibling.
    static func namedField(_ key: String, siblings: [(String, String)]) -> String? {
        guard fieldValueKeys.contains(words(key).joined()), hint(key) == nil else { return nil }
        for (name, value) in siblings where name != key && fieldNameKeys.contains(words(name).joined()) && value.utf16.count <= 80 && !isToken(value) {
            if let field = header(value) { return field }
        }
        return nil
    }
    /// The field a typed identifier's value is, from what its record says it is rather than a
    /// sibling's plain name: `names` in turn (see `JSONDocument.Collector.typeNames`), as
    /// {"system": "…/sid/passport-USA", "type": {"text": "Passport Number"}, "value": …} writes them.
    /// A value whose key says its type ("valueString") is read so too, under its extension's "url".
    static func typedField(_ key: String, names: [String]) -> String? {
        guard !names.isEmpty, fieldValueKeys.contains(words(key).joined()) || isChoiceValue(key), hint(key) == nil else { return nil }
        for name in names { if let field = identifierField(name) { return field } }
        return nil
    }
    /// "valueString", "valueAddress": a record's one value, its key naming the value's type.
    static func isChoiceValue(_ key: String) -> Bool {
        key.hasPrefix("value") && key.dropFirst(5).first?.isUppercase == true
    }
    /// The key a kind of identifier is written under: "Passport Number", "us-ssn", "Medical
    /// Record Number", and with a country's code after it, "passport-USA".
    static func identifierField(_ name: String) -> String? {
        guard name.utf16.count <= 80, !isToken(name) else { return nil }
        if let field = header(name) { return field }
        let parts = words(name)
        if RecordIDs.isPersonKey(name) { return parts.joined(separator: "_") }
        if parts.count >= 2, let last = parts.last, (2...3).contains(last.count), last.allSatisfy(\.isLetter),
           let field = header(parts.dropLast().joined(separator: " ")) { return field }
        return nil
    }
    /// The keys the codes of health records' identifier types (table 0203) stand for: "DL" is a driver's licence.
    static let identifierTypeCodes: [String: String] = [
        "DL": "driver_license_number", "PPN": "passport_number", "SS": "ssn", "TAX": "tax_id", "NI": "national_id", "NPI": "npi", "PRN": "id_number",
        "MR": "mrn", "MRT": "mrn", "PI": "patient_id", "PT": "patient_id", "MA": "member_id", "MC": "member_id", "MB": "member_id", "SN": "subscriber_id"]
    /// The last part of a URI's path, which names what it identifies: "us-ssn" of
    /// "http://hl7.org/fhir/sid/us-ssn". Nil for a URI with no path ("http://hospital.example.org").
    static func uriName(_ value: String) -> String? {
        guard value.utf16.count <= 256, !value.contains(" ") else { return nil }
        let rest: Substring
        if let scheme = value.range(of: "://") {
            rest = value[scheme.upperBound...].drop { $0 != "/" }
        } else if value.lowercased().hasPrefix("urn:") {
            rest = value.dropFirst(4)
        } else { return nil }
        let path = rest.prefix { $0 != "?" && $0 != "#" }
        return path.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
    }
    private static let tokenPart = TextPattern(#"\d[A-Za-z]"#)
    /// A record's own ID ("evt_xNptjX29KGaePinQ"), not a field's name: a digit
    /// runs into letters, as no field name writes it ("address1" and "us-ssn"
    /// do not). Read as words, an ID can spell anything ("Pin").
    static func isToken(_ value: String) -> Bool {
        value.split(whereSeparator: { "_-.:/ ".contains($0) }).contains { !TextRanges.matches(tokenPart, in: String($0)).isEmpty }
    }
    /// The key a flattened or spoken field name stands for, as CSV headers and
    /// form fields write them: "billing_details.address.city", "Applicant Name
    /// First", "Contact Phones 0 Number", "http://hl7.org/fhir/sid/us-ssn".
    static func header(_ name: String) -> String? {
        let found = headerKey(name)
        // "location.coordinates.0": a GeoJSON point's first number is its longitude.
        if hint(found) == "COORDINATES", let position = words(name).last, position == "0" || position == "1" {
            let latitudeFirst = words(found).joined().hasPrefix("lat")
            return (position == "0") == latitudeFirst ? "latitude" : "longitude"
        }
        return found
    }
    private static func headerKey(_ name: String) -> String? {
        if hint(name) != nil { return name }
        let parts = words(name).filter { !$0.allSatisfy(\.isNumber) }
        guard !parts.isEmpty, parts.count <= 12, !countWords.contains(parts[0]) || parts.count == 1 else { return nil }
        var parent: String?
        var resolved: String?
        for index in parts.indices {
            let part = parts[index]
            // The longest run of words ending here that names a field ("postal code").
            var here: String? = nil
            for start in stride(from: max(0, index - 3), through: index, by: 1) {
                let run = parts[start...index].joined(separator: "_")
                let joined = parts[start...index].joined()
                if hint(run) != nil, start == index || hints[joined] != nil || singular(joined).map({ hints[$0] != nil }) == true { here = run; break }
            }
            // "Company Name" and "Plan Name" hold no person; "Billing Details Name" does.
            if isBareName(here ?? part), index > 0, parent == nil,
               notPeople.contains(parts[index - 1]) || !parts[..<index].contains(where: { people.contains($0) || roles.contains($0) || ["billing", "shipping"].contains($0) }) {
                resolved = nil
                continue
            }
            let next = resolve(here ?? part, parent: parent)
            resolved = hint(next) != nil ? next : nil
            if let resolved { parent = resolved }
        }
        return resolved
    }
    /// Keys whose values are timestamps, identifiers, codes and settings: what
    /// they hold is read as written, so a date there is no birth date, a
    /// ten-digit time no phone number and "America/Chicago" no place.
    static func isStructural(_ key: String?) -> Bool {
        guard let key, hint(key) == nil, let last = words(key).last else { return false }
        return structuralWords.contains(last)
    }
    private static let structuralWords: Set<String> = ["at", "time", "timestamp", "date", "created", "updated", "modified", "expires", "expiry", "timezone", "tz", "zone", "locale", "id", "uuid", "guid", "status", "type", "kind", "version", "agent", "useragent", "url", "uri", "href", "path", "method", "currency", "hash", "checksum", "signature", "fingerprint", "sku", "code", "codes", "scope", "role", "plan", "tier", "channel", "format", "encoding", "mime", "mimetype", "algorithm", "country", "nationality",
                                                          // A business in a role, never a person: a card's issuer, a phone's carrier, a payment's network.
                                                          "issuer", "carrier", "brand", "network", "processor", "provider", "institution", "merchant", "bank"]
    private static let needsDigit: Set<String> = ["EXPIRY_DATE", "DATE_OF_BIRTH", "POSTAL_CODE", "US_SSN", "ID_NUMBER", "PHONE_NUMBER", "IP_ADDRESS", "ADDRESS"]
    private static let statusWords: Set<String> = ["match", "mismatch", "matched", "success", "successful", "fail", "failed", "failure", "pass", "passed", "pending", "verified", "unverified", "valid", "invalid", "yes", "no", "true", "false", "null", "nil", "none", "unknown", "active", "inactive", "expired", "redacted", "completed", "canceled", "cancelled", "skipped", "error", "ok", "approved", "rejected", "declined", "missing", "present", "absent", "partial", "exact", "high", "medium", "low", "required", "optional", "enabled", "disabled", "unavailable", "available", "found", "notfound", "nomatch", "fuzzy", "inconclusive", "indeterminate", "review", "accept", "accepted", "reject", "refer", "referred", "flagged", "clear", "cleared", "blocked", "allowed", "confirmed", "unconfirmed", "hit", "nohit", "consider", "manual", "mixed", "masked", "suppressed", "withheld", "na", "n/a"]
    /// Whether a value can be what its key names. Result fields reuse personal
    /// keys for statuses ("first_name": "match", "date_of_birth": "no_match")
    /// and sources ("address": ["USPS"], "firstName": ["Government"]), which are
    /// left to detection instead of becoming names, dates and streets.
    /// A machine's name as DNS writes it: lowercase labels joined by three dots or more, or
    /// by two where one holds a digit or a hyphen ("ip-10-0-3-17.eu-west-1.compute.internal", "db-2.int.example").
    static func hostName(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, text.utf8.count <= 253, let top = labels.last, top.count >= 2, top.allSatisfy({ $0.isASCII && $0.isLowercase }),
              labels.allSatisfy({ label in !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                  && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") } }) else { return false }
        return labels.count >= 4 || labels.contains { $0.contains(where: { $0.isNumber || $0 == "-" }) }
    }
    static func fits(_ key: String?, _ value: String) -> Bool {
        guard let entity = hint(key) else { return true }
        // A field that may hold either of two ("houseNumberOrName": "14" or "Kestrel House") holds what fits one.
        if let either = alternatives(words(key)) { return either.contains { fits($0, value) } }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // A sample that writes its own field's name ("LastName": "LastName") holds no value of it;
        // a password that is the word "password" is still one.
        if entity != "SECRET", trimmed.count >= 4, compactKey(trimmed) == compactKey(key) || compactKey(trimmed) == words(key).joined() { return false }
        // An object's reference named a "token" by an API ("entity_token": "P-MSBW0ff3TQG7IYPvaoHs",
        // "workflow_token", "source_evaluation_tokens"): an ID, which unlocks nothing. Under an
        // "access_token" or "recovery_token" any shape is still a secret, and so is any
        // word in a secret's place ("pass", "string"): a password can be one.
        if entity == "SECRET" {
            let parts = words(key)
            // A template's slot (":case_token") holds none.
            if trimmed.isEmpty || !TextRanges.matches(placeholder, in: trimmed).isEmpty { return false }
            // An enum's word ("FACE", "CUSTOMER", "WEB") in a record a collection of credentials holds;
            // under a credential's own key ("api_key", "client_secret") any spelling is one.
            if let last = parts.last, credentialCollections.contains(last), trimmed.count <= 32,
               trimmed.allSatisfy({ $0.isASCII && ($0.isUppercase || $0 == "_") }) { return false }
            // A card's code and a PIN are digits; a word in their place is a check's result ("cvv": "match").
            if cardCodes.contains(compactKey(key)) || cardCodes.contains(parts.last ?? "") {
                // A country's personal identification number ("pin": "1 1101 00152 64 1", "A006665913Y") is an identifier, not a code.
                if trimmed.count > 8, Recognizers.candidates(trimmed).contains(where: { Recognizers.named($0.context, among: ["pin"]) }) { return false }
                return trimmed.contains(where: \.isNumber)
            }
            guard parts.last == "token" || parts.last == "tokens" else { return true }
            // A bare "token" names an object when it is written as one: a type's code and an ID ("P-tZOLIOQGVxfixICuvkS0").
            guard let qualifier = parts.dropLast().last else { return TextRanges.matches(objectReference, in: trimmed).isEmpty }
            return !referenceQualifiers.contains(qualifier)
        }
        if typeWords.contains(trimmed.lowercased()) { return false }
        // A machine's host name under a "name" ("ip-10-0-3-17.eu-west-1.compute.internal") names no one.
        if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(entity), hostName(trimmed) { return false }
        // A loopback, a public resolver and a network's block ("10.42.0.0/16") are no one's address.
        if entity == "IP_ADDRESS" {
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            if Patterns.sharedAddress(String(parts[0])) || parts.count == 2 && Int(parts[1]).map({ Patterns.networkBlock(String(parts[0]), prefix: $0) }) == true { return false }
        }
        if digestKinds.contains(entity), isDigest(trimmed) { return true }
        if entity == "USERNAME" { return !describes(trimmed) }
        // A zone's line under a line's key ("mrz": {"line2": "EJ4728193…"}), its check digits right, is the zone's, no street.
        if entity == "ADDRESS", MachineZone.isZone(trimmed) { return false }
        // A second address line is a unit ("Apt 4B", "Suite 210", "#12"), not a measure.
        if entity == "ADDRESS", unitKeys.contains(compactKey(key)) || unitKeys.contains(words(key).last ?? "") || unitKeys.contains(words(key).suffix(2).joined()) {
            let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "." }).first.map { $0.lowercased() } ?? ""
            let unitWords: Set<String> = ["apt", "apartment", "suite", "ste", "unit", "floor", "fl", "room", "rm", "bldg", "building", "po", "p", "box", "flat", "level", "lvl", "lot", "block", "blk", "door", "office", "dept", "pmb", "penthouse", "ph", "basement", "bsmt", "trailer", "space", "spc",
                                          "app", "appt", "bât", "bat", "bâtiment"]
            // "Apt A", "Flat C": a unit named by a letter.
            if unitWords.contains(first), trimmed.split(separator: " ").count <= 3 { return true }
            // An address's further lines ("address2": "Paddington", "line2": "c/o Fernbrook Farm") are the address, whatever they hold;
            // a bare "unit" or "apt" may be a measure's or a flag's.
            if lineKeys.contains(compactKey(key)) || lineKeys.contains(words(key).suffix(2).joined()) {
                // A sample's label for the line ("Address Line 2", "Apt/Suite") holds none.
                let lineWords: Set<String> = ["address", "addr", "line", "street", "apt", "apartment", "suite", "unit", "floor", "optional", "second", "third", "two", "three", "2", "3", "here", "or", "and"]
                if words(trimmed).allSatisfy(lineWords.contains) { return false }
                return trimmed.contains(where: { $0.isLetter || $0.isNumber }) && !isCommonValue(trimmed) && !placeholderOpenings.contains(where: { trimmed.lowercased().hasPrefix($0) }) && trimmed.utf16.count <= 120
            }
            // "Apt 23", "#12", "4B", and a floor named by its number ("11th floor").
            // So is a unit as another country writes one ("3º B", "2. OG").
            return trimmed.contains(where: \.isNumber) && (unitWords.contains(first) || trimmed.hasPrefix("#") || !trimmed.contains(" ") && trimmed.count <= 6 || AddressBlock.isUnit(trimmed)
                || trimmed.split(separator: " ").count <= 3 && trimmed.lowercased().split(separator: " ").contains { ["floor", "fl", "suite", "unit"].contains(String($0)) })
        }
        // A house number is short: "12", "12A", "12-14", "12 bis".
        if entity == "ADDRESS", houseNumberKeys.contains(compactKey(key)) || houseNumberKeys.contains(words(key).suffix(2).joined()) {
            return trimmed.contains(where: \.isNumber) && trimmed.count <= 10 && trimmed.split(separator: " ").count <= 2
        }
        // A street's or a building's name has no number: "Via Garibaldi", "Hauptstraße", "Kestrel House".
        if entity == "ADDRESS", !trimmed.contains(where: \.isNumber), streetNameKeys.contains(compactKey(key)) || streetNameKeys.contains(words(key).suffix(2).joined()) || streetNameKeys.contains(words(key).last ?? "") {
            return trimmed.contains(where: \.isLetter) && !statusWords.contains(trimmed.lowercased()) && !trimmed.contains("_")
                && !placeholderOpenings.contains(where: { trimmed.lowercased().hasPrefix($0) })
        }
        // Under its own key a zone is replaced by its shape, whatever its check digits say.
        if entity == "MRZ" { return MachineZone.isShaped(trimmed) }
        // An IP address under "address" ("ip": {"address": "94.142.239.124"}) is no street.
        if entity == "ADDRESS", trimmed.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }), trimmed.contains(".") && trimmed.filter({ $0 == "." }).count == 3 || trimmed.filter({ $0 == ":" }).count >= 2 { return false }
        // A birth month may be written as its name: "birth_month": "March".
        if entity == "DATE_OF_BIRTH", StandIns.month(trimmed) != nil, datePart(key) == .month { return true }
        if needsDigit.contains(entity) {
            // A score ("0.74") rates the field; a phone number has at least seven digits.
            let unsigned = trimmed.first == "-" || trimmed.first == "+" ? trimmed.dropFirst() : Substring(trimmed)
            if let point = unsigned.firstIndex(of: "."), point < unsigned.index(before: unsigned.endIndex),
               unsigned.allSatisfy({ $0 == "." || $0.isASCII && $0.isNumber }), unsigned.filter({ $0 == "." }).count == 1 { return false }
            if entity == "PHONE_NUMBER" { return trimmed.filter(\.isNumber).count >= 7 }
            // A whole birth date is never one digit: "dob": 1 is a check's result.
            if trimmed.count == 1, entity == "DATE_OF_BIRTH", datePart(key) == nil { return false }
            return trimmed.contains(where: \.isNumber)
        }
        if entity == "EMAIL_ADDRESS" { return trimmed.contains("@") || trimmed.range(of: "%40", options: .caseInsensitive) != nil }
        // "state": "open" and "region": "us-east-1" hold no place.
        // A region of birth may be any country's ("Jalisco", "OAXACA"): a word or two of letters.
        if entity == "REGION", words(key).contains("birth") || words(key).contains("registration") { return Places.region(trimmed) != nil || trimmed.split(separator: " ").count <= 3 && trimmed.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" } && !isCommonValue(trimmed) }
        // A Mexican or Indian state, a Brazilian one's code ("Jalisco", "SP") is a region as a US one is.
        if entity == "REGION" { return Places.region(trimmed) != nil || Places.regionAbroad(trimmed) != nil }
        if entity == "LATITUDE" || entity == "LONGITUDE" { return coordinate(trimmed, limit: entity == "LATITUDE" ? 90 : 180) }
        if entity == "COORDINATES" {
            let pair = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && coordinate(pair[0], limit: 180) && coordinate(pair[1], limit: 180)
        }
        if entity == "AGE" { return Int(trimmed).map { (0...120).contains($0) } ?? false }
        // "OB", "O.B.", "O. A. B."
        if entity == "INITIALS" {
            let letters = trimmed.filter { $0 != "." && $0 != " " }
            return (1...4).contains(letters.count) && letters.allSatisfy { $0.isLetter && $0.isUppercase }
        }
        // "7784", "***-**-7784", "•••• 1111"
        if entity == "LAST_DIGITS" {
            return trimmed.filter(\.isNumber).count == 4 && trimmed.allSatisfy { $0.isNumber || "*•xX#- .".contains($0) }
        }
        // A score ("0.86") or a count rates the field; a name has letters.
        if ["PERSON", "FIRST_NAME", "LAST_NAME", "LOCATION"].contains(entity), !trimmed.contains(where: \.isLetter) { return false }
        if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(entity), NameTagger.namesOrganisation(trimmed) { return false }
        // Statuses are words joined by underscores ("partial_match", "NO_MATCH"),
        // lowercase or in capitals.
        let folded = trimmed == trimmed.uppercased() ? trimmed.lowercased() : trimmed
        let status = !folded.isEmpty && folded.first != "_" && folded.last != "_" && !folded.contains("__")
            && folded.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return !status || !folded.contains("_") && !statusWords.contains(folded)
    }
    /// A value an address field holds that `fits` turns down for having no
    /// number, but that reads as a place: words of letters, more than one,
    /// and no status, placeholder or note ("same as billing", "n/a"). Such a
    /// value is replaced as an address when its record's other address parts
    /// are (see `DocumentPipeline`): "the old rectory, church lane" beside a
    /// city and a postcode is the rest of that address.
    static func numberlessLine(_ key: String?, _ value: String) -> Bool {
        guard hint(key) == "ADDRESS" else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines), lower = trimmed.lowercased()
        let words = lower.split { !$0.isLetter && $0 != "'" && $0 != "’" }
        guard !trimmed.contains(where: \.isNumber), words.count >= 2, trimmed.filter(\.isLetter).count >= 5, !typeWords.contains(lower), !statusWords.contains(lower),
              !placeholderOpenings.contains(where: { lower.hasPrefix($0) }) else { return false }
        // A zone's names line under "line1" ("P<GBRADEBAYO<OKAFOR<<…") is the zone's, no street.
        return !lower.contains("_") && !MachineZone.isShaped(trimmed)
    }
    /// A province's code that `fits` turns down for being no US, Canadian or
    /// Australian region ("NA", "TO" beside an Italian city): replaced only
    /// beside the rest of its address, as `numberlessLine` is.
    static func regionCode(_ key: String?, _ value: String) -> Bool {
        guard hint(key) == "REGION", !fits(key, value) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // A country's three letters ("issuing_state": "NLD") name its country, never a province.
        if trimmed.count == 3, Places.code(trimmed) != nil { return false }
        return (2...3).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && $0.isUppercase }
    }
    /// A plan's or a product's name in words ("Team plan (monthly)", "Pro annual"):
    /// a capitalised word, then ordinary words in small letters or a note in brackets. No one's handle.
    static func describes(_ value: String) -> Bool {
        let words = value.split(separator: " ").map(String.init)
        guard words.count >= 2, words[0].first?.isUppercase == true else { return false }
        if value.contains("(") && value.hasSuffix(")") { return true }
        return words.dropFirst().allSatisfy { $0.first?.isLowercase == true && NameLists.isOrdinary($0) && !NameLists.isFirst($0) }
    }
    private static let noteMark = TextPattern(#"[ \t]+(?:-{2,}|[—–|])[ \t]+"#)
    /// Where a note written after a field's value begins ("128 -- gate code on file",
    /// "Marisol — checked by phone", "94103 | verified"): a run of dashes, a long dash or a bar
    /// with spaces around it, then words. The value is what comes before; nil for a value with no note.
    static func noteStart(_ value: String) -> Int? {
        guard value.utf16.count <= 4096, let mark = TextRanges.matches(noteMark, in: value).first, mark.range.location > 0 else { return nil }
        let head = TextRanges.substring(value, 0..<mark.range.location), tail = TextRanges.substring(value, NSMaxRange(mark.range)..<(value as NSString).length)
        guard head.contains(where: { $0.isLetter || $0.isNumber }), tail.filter(\.isLetter).count >= 2 else { return nil }
        return mark.range.location
    }
    /// The value a field's key is judged against: what comes before a note written after it (see `noteStart`).
    /// A secret is whole whatever it holds.
    static func judged(_ key: String?, _ value: String) -> String {
        guard let entity = hint(key), entity != "SECRET" else { return value }
        let contact = entity == "ADDRESS" || entity == "LOCATION" ? contactStart(value) : nil
        guard let cut = [noteStart(value), contact].compactMap({ $0 }).min() else { return value }
        return TextRanges.substring(value, 0..<cut)
    }
    private static let contactLabel = TextPattern(#"(?<=[\s,;.|/(—–-])\p{L}[\p{L}-]*\.?:?\s*(?=[+(\d]|[^\s@]+@)"#)
    private static let email = TextPattern(#"(?<![^\s,;:(<\[—–-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+"#)
    /// Where a phone number or an email written after a place starts ("Lindenstraße 14, 50674 Köln,
    /// Tel. 0221 …, E-Mail h.l@example.de"): its label, or the email itself. A place holds neither.
    static func contactStart(_ value: String) -> Int? {
        guard value.utf16.count <= 4096 else { return nil }
        let ns = value as NSString
        let labelled = TextRanges.matches(contactLabel, in: value).first { match in
            let word = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: " \t.:"))
            return ["PHONE_NUMBER", "EMAIL_ADDRESS"].contains(hint(word) ?? "")
        }?.range.location
        let cut = [labelled, TextRanges.matches(email, in: value).first?.range.location].compactMap { $0 }.min()
        guard let cut, cut > 0, TextRanges.substring(value, 0..<cut).contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return cut
    }
    private static let placeholderOpenings = ["same as", "see ", "as above", "as per", "not ", "no ", "none", "unknown", "n/a", "tbd", "tbc", "redacted", "withheld", "remote", "various", "pending", "to be ", "on file", "same"]
    /// A key that holds a house or a unit's number, which may be written as a bare number.
    static func addressNumberKey(_ key: String?) -> Bool {
        let parts = words(key)
        if let either = alternatives(parts), hint(key) != nil { return either.contains { addressNumberKey($0) } }
        return hint(key) == "ADDRESS" && [houseNumberKeys, unitKeys].contains { $0.contains(parts.joined()) || $0.contains(parts.suffix(2).joined()) || $0.contains(parts.last ?? "") }
    }
    /// A key that names a unit alone ("unit", "units", "apt", "flat"): a sales
    /// file's quantity or a measure as often as an address's unit.
    static func bareUnitKey(_ key: String?) -> Bool {
        let compact = compactKey(key)
        return hint(key) == "ADDRESS" && bareUnits.contains(singular(compact).flatMap { bareUnits.contains($0) ? $0 : nil } ?? compact)
    }
    private static let bareUnits: Set<String> = ["unit", "apt", "flat"]
    // "primary_number": a US address's house number, as address validation splits it.
    static let houseNumberKeys: Set<String> = ["housenumber", "housenum", "houseno", "primarynumber", "buildingnumber", "buildingno", "streetnumber", "streetnum", "streetno", "civicnumber", "premisenumber"]
    static let streetNameKeys: Set<String> = ["streetname", "thoroughfare", "buildingname", "street", "housename", "straat", "strasse", "calle", "ulica"]
    private static let unitKeys: Set<String> = ["unit", "apt", "apartment", "street2", "address2", "addr2", "line2", "addressline2", "streetline2", "aptsuite", "apartmentnumber", "aptnumber", "suitenumber", "unitnumber", "flatnumber", "addressline3", "line3", "flat", "flatno", "address3", "addr3", "street3"]
    private static let lineKeys: Set<String> = ["street2", "address2", "addr2", "line2", "addressline2", "streetline2", "addressline3", "line3", "address3", "addr3", "street3", "extendedaddress", "streetaddress2"]
    private static func compactKey(_ key: String?) -> String { (key ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    /// A coordinate written to at least two decimals ("47.2529"); a bare 47 is a count.
    private static func coordinate(_ text: String, limit: Double) -> Bool {
        guard let value = Double(text), abs(value) <= limit, let point = text.firstIndex(of: ".") else { return false }
        return text[text.index(after: point)...].count >= 2 && text[text.index(after: point)...].allSatisfy(\.isNumber)
    }
    // Code declares fields with their types (`email: string`, `first_name: str`).
    private static let typeWords: Set<String> = ["string", "str", "number", "int", "integer", "bool", "boolean", "float", "double", "decimal", "date", "datetime", "object", "any", "unknown", "void", "undefined", "none", "null", "nil", "text", "varchar", "char", "uuid", "list", "dict", "array", "optional", "string?", "string | null", "str | none", "optional[str]"]
    /// The key a value is read under when its own key names an expiry and the record is a
    /// card's or an identity document's: "expiry_date" beside a card's number or last four
    /// digits, under "cards" or "personal_ids", or in a record whose kind is a passport.
    /// Nil for any other expiry, a token's, a link's or an offer's.
    static func expiry(_ key: String, siblings: [String], parent: String?, kind: Set<String>) -> String? {
        guard hint(key) == nil, expiryKeys.contains(words(key).joined()) else { return nil }
        let owned = !Set(words(parent)).isDisjoint(with: expiryOwners) || !kind.isDisjoint(with: expiryOwners)
            || siblings.contains { sibling in
                ["CREDIT_CARD", "LAST_DIGITS", "ID_NUMBER", "MRZ"].contains(hint(sibling) ?? "") || cardFields.contains(words(sibling).joined())
            }
        return owned ? "card_expiry" : nil
    }
    static func isExpiryKey(_ key: String) -> Bool { expiryKeys.contains(words(key).joined()) }
    private static let expiryKeys: Set<String> = ["expiry", "expirydate", "expiration", "expirationdate", "expdate", "expires", "expireson", "validthru", "validthrough", "validuntil", "validto", "dateofexpiry", "expirydt", "expirationdt"]
    private static let expiryOwners: Set<String> = ["card", "cards", "creditcard", "debitcard", "license", "licenses", "licence", "licences", "passport", "passports", "document", "documents", "doc", "docs", "iddoc", "iddocs",
                                                    "ids", "identification", "identifications", "certificate", "certificates", "permit", "permits", "debitcards", "creditcards", "driverslicense", "driverlicense"]
    private static let cardFields: Set<String> = ["bin", "cardbin", "iin", "pan", "cardbrand", "cardtype", "cardholder", "cardholdername", "nameoncard", "embossname", "embossedname", "lastfourdigits", "last4digits",
                                                  "documentnumber", "issuingcountry", "issuedate", "dateofissue", "issuingauthority", "issuingstate", "licensenumber", "passportnumber"]
    /// The key a date's field is read under in a record about a birth: a record whose kind
    /// is one ({"type": "BIRTH", "fullDate": …, "year": …}), or a year beside a person's
    /// name ({"name": "Lucan Brierly", "year": 1952}), the year a search for them gives.
    static func birthField(_ key: String, value: String?, siblings: [(String, String)], kind: Set<String>) -> String? {
        guard hint(key) == nil else { return nil }
        let compact = words(key).joined()
        if !kind.isDisjoint(with: ["birth", "dob", "birthdate", "born", "birthday"]), let field = birthFields[compact] { return field }
        guard compact == "year" || compact == "yyyy", let value, value.count == 4, let year = Int(value),
              (1900...(Calendar(identifier: .gregorian).component(.year, from: Date()) - 10)).contains(year) else { return nil }
        let named = siblings.contains { sibling, text in
            guard let field = hint(sibling), ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(field) else { return false }
            return !isBareName(sibling) || bareNameIsPerson(text, siblings: siblings.map(\.0), parent: nil)
                || text.split(separator: " ").count >= 2 && Detector.writtenName(text).map { $0.count == (text as NSString).length } == true
        }
        return named ? "birth_year" : nil
    }
    /// Whether a key could hold a birth's date or a part of it, for `birthField` to judge with its record.
    static func mayBeBirthPart(_ key: String) -> Bool { birthFields[words(key).joined()] != nil }
    private static let birthFields: [String: String] = ["date": "date_of_birth", "fulldate": "date_of_birth", "value": "date_of_birth", "datetime": "date_of_birth", "datetimevalue": "date_of_birth",
                                                        "datevalue": "date_of_birth", "year": "birth_year", "yyyy": "birth_year", "month": "birth_month", "day": "day_of_birth"]
    /// A bare "name" key, or its abbreviation "nm", which names accounts, products and plans as often as people.
    static func isBareName(_ key: String?) -> Bool {
        let parts = words(key)
        return parts == ["name"] || parts == ["nm"]
    }
    private static let personalSiblings: Set<String> = ["PERSON", "FIRST_NAME", "LAST_NAME", "EMAIL_ADDRESS", "PHONE_NUMBER", "DATE_OF_BIRTH", "US_SSN", "ID_NUMBER", "USERNAME"]
    private static let people: Set<String> = ["user", "customer", "contact", "employee", "patient", "person", "people", "member", "owner", "student", "applicant", "candidate", "passenger", "traveler", "traveller", "signer", "signatory", "holder", "accountholder", "cardholder", "author", "profile", "individual", "borrower", "tenant", "buyer", "seller", "payee", "payer", "driver", "worker", "staff", "teammate", "actor", "guest", "debtor", "creditor", "receiver", "originator", "beneficiary", "associate"]
    private static let notPeople: Set<String> = ["business", "company", "organization", "organisation", "merchant", "employer", "vendor", "institution", "bank", "product", "plan", "model", "account", "app", "application", "project", "team", "workflow", "enrichment", "template", "school"]
    /// Whether a bare "name" holds a person: its record also holds personal details,
    /// its parent is about people ("customers", "manager"), the value uses a known
    /// first or last name, or an email beside it spells it. Otherwise, as for
    /// "Everyday Checking", detection decides (see `writtenAsName` for what it can't).
    /// `inObject`: the siblings are one object's, not every key in loose text.
    /// `values`: the record's other strings, whatever their keys.
    static func bareNameIsPerson(_ value: String, siblings: [String], parent: String?, inObject: Bool = true, values: [String] = []) -> Bool {
        // A list of a person's other names ("aka": [{"name": …}]) holds names, in any script and of one word too.
        if ["PERSON", "FIRST_NAME", "LAST_NAME"].contains(hint(parent) ?? ""), value.contains(where: \.isLetter), !isCommonValue(value) { return true }
        if spelledByEmail(value, in: values) { return true }
        guard let known = nameEvidence(value) else { return false }
        if isNotPeople(parent) { return ownRecord(siblings, value: value) }
        return isPersonsRecord(siblings: siblings, parent: parent, inObject: inObject) || known || housed(value, siblings: siblings, parent: parent)
    }
    /// Whether a bare "name" beside a street address is the person living there: written as
    /// a person's name, none of its words an ordinary one ("Anđa Tomić", not "Riverside Clinic").
    /// A name the lists don't hold may have a rare dictionary word in it ("Ilka Sztojka"): it is
    /// still the addressee when no word of it is ordinary nor a business's (see `Detector.readsAsAddressee`).
    private static func housed(_ value: String, siblings: [String], parent: String?) -> Bool {
        guard siblings.contains(where: { !isBareName($0) && hint($0) == "ADDRESS" }), !isNotPeople(parent) else { return false }
        if writtenAsName(value, parent: parent) && onlyNames(value) { return true }
        let trimmed = value.trimmingCharacters(in: .whitespaces), words = trimmed.split(separator: " ").map(String.init)
        return (2...4).contains(words.count) && Detector.writtenName(trimmed) == 0..<(trimmed as NSString).length
            && !words.contains { NameLists.isOrdinary($0) || NameLists.isWordlike($0) } && Detector.readsAsAddressee(words)
    }
    /// `bareNameIsPerson` under no parent, with `isPersonsRecord` of its
    /// siblings read once for every value beside them.
    static func bareNameIsPerson(_ value: String, personsRecord: Bool) -> Bool {
        guard let known = nameEvidence(value) else { return false }
        return personsRecord || known
    }
    /// Whether a bare "name"'s value uses a known first or last name, or nil
    /// where it cannot be a person's whatever its record holds.
    private static func nameEvidence(_ value: String) -> Bool? {
        let parts = value.split(whereSeparator: { !$0.isLetter })
        // A surname's particle between capitalised words ("Odalys van der Berg") writes a person's name.
        let particled = parts.count >= 3 && parts.first?.first?.isUppercase == true && parts.last?.first?.isUppercase == true
            && parts.dropFirst().dropLast().contains { surnameParticles.contains(String($0)) } && Detector.writtenName(value) != nil
        // A name the long lists hold opening words written as a name ("Jim Doe", "Ian Penhale"), not an ordinary word ("Chase Sapphire").
        let listed = (2...4).contains(parts.count) && NameLists.isFirst(String(parts[0])) && !NameLists.isOrdinary(String(parts[0])) && Detector.writtenName(value) != nil
        // Written as a name in another script ("Йоана Петрова"), which a product's name seldom is in an API's data.
        let otherScript = (2...4).contains(parts.count) && value.unicodeScalars.contains { $0.value >= 0x0370 && $0.properties.isAlphabetic }
            && parts.allSatisfy { $0.first.map { $0.isUppercase || !$0.isCased } == true }
        // A surname the long lists hold closing a name whose first word is no ordinary one ("Tomasz Wierzbicki"), not "Burger King".
        let surnamed = (2...4).contains(parts.count) && NameLists.isSurname(String(parts[parts.count - 1])) && !NameLists.isWord(String(parts[parts.count - 1]))
            && !NameLists.isWord(String(parts[0])) && Detector.writtenName(value) != nil
        // Chinese, Japanese or Korean written whole ("王秀英"): a common surname leading it says whose; with none, the record decides.
        if let eastAsian = EastAsianNames.surnamed(value) { return eastAsian }
        let known = particled || listed || surnamed || otherScript || parts.contains { Names.firstFolded.contains($0.lowercased()) || Names.lastFolded.contains($0.lowercased()) }
        // One unknown word ("NORTHWIND") names a business or product more often than a person.
        if parts.count < 2 && !known { return nil }
        return known
    }
    /// Whether a bare "name" nothing says is a person's is still written as one: two to four
    /// capitalised words, none an ordinary word or a business's ("Hamish Olawale", not
    /// "Everyday Checking"), or a Chinese, Japanese or Korean name's shape. Kept as written,
    /// it is put to a person in review, never kept unseen. Under a business, a product
    /// or an app ("merchant": {"name": …}) it is theirs.
    static func writtenAsName(_ value: String, parent: String?) -> Bool {
        guard !isNotPeople(parent) else { return false }
        if EastAsianNames.surnamed(value) != nil { return true }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard (2...4).contains(trimmed.split(separator: " ").count), Detector.writtenName(trimmed) == 0..<(trimmed as NSString).length else { return false }
        return !trimmed.split(whereSeparator: { !$0.isLetter }).contains { part in
            let word = String(part)
            return NameLists.isWord(word) && !NameLists.isFirst(word) && !NameLists.isSurname(word)
        }
    }
    /// Whether every word of a value `writtenAsName` passed is a name or no word at all:
    /// "Hamish Olawale", not "Land Berlin". Such a value the name model reads as a
    /// person's is replaced; any other is put to a person.
    static func onlyNames(_ value: String) -> Bool {
        value.split(whereSeparator: { !$0.isLetter }).allSatisfy { part in
            let word = String(part)
            return NameLists.isName(word) || !NameLists.isWord(word)
        }
    }
    /// Whether an email among `values` spells `name` in its local part: its surname with the
    /// first name or its initial ("hamish.olawale@", "holawale@"), or the first name with the
    /// surname's initial ("hamisho@"). Its owner is the person named.
    static func spelledByEmail(_ name: String, in values: [String]) -> Bool {
        guard !values.isEmpty else { return false }
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard (2...4).contains(words.count), let first = words.first, let last = words.last, first.count >= 2, last.count >= 3 else { return false }
        return values.contains { value in
            guard value.utf16.count <= 254, let at = value.firstIndex(of: "@"), at > value.startIndex, !value.contains(where: \.isWhitespace),
                  value[value.index(after: at)...].contains(".") else { return false }
            let local = String(value[..<at].folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter(\.isLetter))
            return local.contains(last) && (local.contains(first) || local.hasPrefix(String(first.prefix(1))))
                || first.count >= 3 && local.hasPrefix(first) && local.dropFirst(first.count).hasPrefix(String(last.prefix(1)))
        }
    }
    /// Whether a key names a business, a product or an app ("application", "accounts").
    static func isNotPeople(_ key: String?) -> Bool {
        guard let key else { return false }
        return notPeople.contains(words(key).last.map { singular($0) ?? $0 } ?? "")
    }
    /// Fields only a person has, written as the record's own ("dob", not "contact_dob").
    private static let ownFields: Set<String> = ["FIRST_NAME", "LAST_NAME", "DATE_OF_BIRTH", "US_SSN"]
    private static let contactFields: Set<String> = ["EMAIL_ADDRESS", "PHONE_NUMBER"]
    /// Whether a record under a parent that names no one ("application",
    /// "account") is still a person's own: a field only a person has sits
    /// beside its "name" (a birth date, an SSN, a first name), or an email or
    /// a phone does and `value` is written as a person's name with a known
    /// first name. "Ledgerly" beside a "version", or "Ledgerly Cloud" beside a
    /// support email, is no one.
    static func ownRecord(_ siblings: [String], value: String?) -> Bool {
        ownRecord(RecordFields(siblings), value: value)
    }
    /// What `ownRecord` reads of a record's fields, read once for any number of values.
    struct RecordFields {
        let own: Bool, contact: Bool
        init(_ siblings: [String]) {
            let fields = Set(siblings.filter { !isBareName($0) && personPrefix($0) == nil }.compactMap(hint))
            own = !fields.isDisjoint(with: ownFields)
            contact = !fields.isDisjoint(with: contactFields)
        }
    }
    static func ownRecord(_ fields: RecordFields, value: String?) -> Bool {
        if fields.own { return true }
        guard let value, fields.contact else { return false }
        let parts = value.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return parts.count >= 2 && NameLists.isFirst(parts[0]) && !NameLists.isOrdinary(parts[0]) && Detector.writtenName(value) != nil
    }
    /// Particles that write a surname and seldom a business's or a product's name.
    private static let surnameParticles: Set<String> = ["van", "von", "der", "den", "ter", "ten", "bin", "ibn"]
    /// Whether a record says a bare "name" in it is a person's, whatever the
    /// name: it holds personal details or a person's own ID, or its parent is
    /// about people ("customers", "manager") and not about a business.
    static func isPersonsRecord(siblings: [String], parent: String?, inObject: Bool = true) -> Bool {
        if isNotPeople(parent) { return ownRecord(siblings, value: nil) }
        if siblings.contains(where: { !isBareName($0) && hint($0).map(personalSiblings.contains) == true }) { return true }
        // A person's own ID beside it ("customer_id", "patient_id") says the record is theirs.
        if inObject, siblings.contains(where: { hint($0) == nil && RecordIDs.isPersonKey($0) }) { return true }
        guard let parent else { return false }
        let compact = parent.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let last = words(parent).last ?? ""
        return isRole(parent) || [compact, last, singular(compact) ?? "", singular(last) ?? ""].contains(where: people.contains)
    }
    // Keys naming a person's role ("assigned_to", "manager") often hold an ID
    // or an email, so they only mark a value that is written like a name.
    private static let roles: Set<String> = ["manager", "approver", "reporter", "author", "assignee", "assignedto", "owner", "requester", "requestedby", "reviewer", "reviewedby", "sender", "recipient", "createdby", "updatedby", "modifiedby", "submittedby", "approvedby", "contact", "contactperson", "agent", "rep", "salesrep", "accountmanager", "supervisor", "signedby", "attendee", "guest", "beneficiary", "emergencycontact", "nextofkin", "spouse", "parent", "guardian", "customer", "client", "patient", "applicant", "employee", "member", "guest", "tenant", "borrower", "insured", "policyholder", "passenger", "traveler", "traveller", "attn", "attention", "shipto", "billto", "soldto", "deliverto", "addressee", "cardholder", "accountholder", "signer", "witness", "caller", "visitor", "student", "candidate", "cosigner", "cosignatory", "guarantor", "coapplicant", "coborrower", "cotenant", "holder", "mother", "father"]
    static func isRole(_ key: String?) -> Bool {
        guard let key else { return false }
        let parts = words(key)
        guard let last = parts.last else { return false }
        return roles.contains(parts.joined()) || roles.contains(last) || parts.count >= 2 && roles.contains(parts[parts.count - 2] + last)
    }
    /// Qualifiers that say which of several people a field is about, beside
    /// the roles and people above: "primary_", "secondary_", and "billing_"
    /// or "shipping_" when they hold a name.
    private static let personQualifiers: Set<String> = ["primary", "secondary", "billing", "shipping"]
    /// The person a flat key's qualifier names ("applicant" of "applicant_email",
    /// "applicantDob" or "co_signer_first_name"), when the rest of it is a field
    /// of its own; nil for a key with none ("first_name", "home_phone", "created_at").
    static func personPrefix(_ key: String?) -> String? {
        let parts = words(key)
        guard parts.count >= 2, parts.count <= 6 else { return nil }
        for length in [2, 1] where parts.count > length {
            let prefix = parts[..<length].joined()
            guard people.contains(prefix) || roles.contains(prefix) || personQualifiers.contains(prefix) else { continue }
            let rest = parts[length...]
            // "user_name" is a username, and "contact_person" or "account_holder" one role.
            guard hint(rest.joined(separator: "_")) != nil, !roles.contains(rest.joined()), hint(key) != nil else { continue }
            return prefix
        }
        return nil
    }
    /// The words of a key: "billing_details.postalCode" → billing, details, postal, code.
    public static func words(_ key: String?) -> [String] {
        guard let key else { return [] }
        var result: [String] = []
        var current = ""
        var previous: Character?
        // Where the token being read began: generated classes name every member "<field>Field"
        // ("nameField", "address2Field", "locationField_coordinatesField_0"), and the field is the rest.
        var tokenStart = 0
        func endToken() {
            if result.count - tokenStart >= 2, result.last == "field" { result.removeLast() }
            tokenStart = result.count
        }
        for character in key {
            if character.isLetter || character.isNumber {
                // camelCase: a capital after a lowercase letter or a digit starts a word.
                if let previous, ("a"..."z").contains(previous) || ("0"..."9").contains(previous), ("A"..."Z").contains(character), !current.isEmpty {
                    result.append(current.lowercased())
                    current = ""
                }
                current.append(character)
            } else if !current.isEmpty {
                result.append(current.lowercased())
                current = ""
                endToken()
            } else {
                endToken()
            }
            previous = character
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        endToken()
        return result
    }
}
