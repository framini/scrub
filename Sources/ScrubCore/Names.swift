public enum Names {
    public static let first: [String] = """
    Ana James Mary John Patricia Robert Jennifer Michael Linda William Elizabeth David Barbara Richard Susan Joseph Jessica Thomas Sarah Charles Karen Christopher Nancy Daniel Lisa Matthew Betty Anthony Margaret Mark Sandra Donald Ashley Steven Kimberly Paul Emily Andrew Donna Joshua Michelle Kenneth Carol Kevin Amanda Brian Melissa George Deborah Timothy Stephanie Ronald Rebecca Edward Laura Jason Sharon Jeffrey Cynthia Ryan Kathleen Jacob Amy Gary Shirley Nicholas Angela Eric Helen Jonathan Anna Stephen Brenda Larry Pamela Justin Nicole Scott Emma Brandon Samantha Benjamin Katherine Samuel Christine Gregory Debra Alexander Rachel Patrick Carolyn Frank Janet Raymond Catherine Jack Maria Dennis Heather Jerry Diane Tyler Ruth Aaron Julie Jose Olivia Adam Joyce Nathan Virginia Henry Victoria Douglas Kelly Zachary Lauren Peter Christina Kyle Joan Walter Evelyn Ethan Judith Jeremy Megan Harold Andrea Keith Cheryl Christian Hannah Roger Jacqueline Noah Martha Gerald Gloria Carl Teresa Terry Ann Sean Sara Austin Madison Arthur Frances Lawrence Kathryn Jesse Janice Dylan Jean Bryan Abigail Joe Alice Jordan Julia Billy Judy Bruce Sophia Albert Grace Willie Denise Gabriel Amber Logan Doris Alan Marilyn Juan Danielle Wayne Beverly Roy Isabella Ralph Theresa Randy Diana Eugene Natalie Vincent Brittany Russell Charlotte Louis Marie Philip Kayla Bobby Alexis Johnny Lori Bradley Tiffany Harry Chloe Fred Wanda Howard Crystal Martin Erica Craig Rosie Tristan Eva Caleb Leah Oscar Ruby Victor Sophia Edgar Lily Frederick Naomi Stanley Clara Leonard Ella Adrian Mia Ivan Zoe Colin Lucy Marcus Nora Julian Hazel Xavier Stella Simon Aurora Omar Audrey Liam Harper Lucas Eleanor Mason Violet Elijah Penelope Oliver Aria Sebastian Scarlett Aiden Layla Carter Mila Owen Claire Wyatt Skylar Luke Paisley Levi Genesis Isaac Kennedy Lincoln Samantha Theodore Allison Jackson Madelyn Mateo Maya Hudson Willow Grayson Aubrey Ezra Brooklyn Asher Bella Leo Savannah Elias Elena Roman Sarah Jaxon Caroline Miles Nova Isaiah Emilia Josiah Everly Charles Valentina Caleb Natalie Christopher Quinn Ezekiel Ivy Cooper Josephine Joshua Cora Angel Jade Anthony Alice Dylan Autumn Jayden Adeline Gabriel Serenity Nathan Anna Thomas Kaylee
    """.split(separator: " ").map(String.init)
    public static let last: [String] = """
    Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson Martin Lee Perez Thompson White Harris Sanchez Clark Ramirez Lewis Robinson Walker Young Allen King Wright Scott Torres Nguyen Hill Flores Green Adams Nelson Baker Hall Rivera Campbell Mitchell Carter Roberts Gomez Phillips Evans Turner Diaz Parker Cruz Edwards Collins Reyes Stewart Morris Morales Murphy Cook Rogers Gutierrez Ortiz Morgan Cooper Peterson Bailey Reed Kelly Howard Ramos Kim Cox Ward Richardson Watson Brooks Chavez Wood James Bennett Gray Mendoza Ruiz Hughes Price Alvarez Castillo Sanders Patel Myers Long Ross Foster Jimenez Powell Jenkins Perry Russell Sullivan Bell Coleman Butler Henderson Barnes Gonzales Fisher Vasquez Simmons Romero Jordan Patterson Alexander Hamilton Graham Reynolds Griffin Wallace Moreno West Cole Hayes Bryant Herrera Gibson Ellis Tran Medina Aguilar Stevens Murray Ford Castro Marshall Owens Harrison Fernandez McDonald Woods Washington Kennedy Wells Vargas Henry Chen Freeman Webb Tucker Guzman Burns Crawford Olson Simpson Porter Hunter Gordon Mendez Silva Shaw Snyder Mason Dixon Munoz Hunt Hicks Holmes Palmer Wagner Black Robertson Boyd Rose Stone Salazar Fox Warren Mills Meyer Rice Schmidt Garza Daniels Ferguson Nichols Stephens Soto Weaver Ryan Gardner Payne Grant Dunn Kelley Spencer Hawkins Arnold Pierce Vazquez Hansen Peters Santos Hart Bradley Knight Elliott Cunningham Duncan Armstrong Hudson Carroll Lane Riley Andrews Alvarado Ray Delgado Berry Perkins Hoffman Johnston Matthews Pena Richards Contreras Willis Carpenter Lawrence Sandoval Guerrero George Chapman Rios Estrada Ortega Watkins Greene Nunez Wheeler Valdez Harper Burke Larson Santiago Maldonado Morrison Franklin Carlson Austin Dominguez Carr Carrillo Silva O'Brien Porter Brock Hardy Fuller Schultz Fields Fletcher Davidson Lynch McCoy Vasquez Holland Nicholson Walsh Austin McKenzie Shields Newman Brewer Barber Horton Stanley Abbott Rojas Norton Little Bradford Hines Sharp Bowen Barber Erickson Doyle Bass Townsend Chambers Schmidt McDaniel Larson Osborne Brock Harmon Ford Marks Bowman Pearson Hardy Floyd Berry Doyle Hanson Brewer
    """.split(separator: " ").map(String.init)
    public static let cities: [String] = """
    New York,Los Angeles,Chicago,Houston,Phoenix,Philadelphia,San Antonio,San Diego,Dallas,Jacksonville,Austin,Fort Worth,San Jose,Columbus,Charlotte,Indianapolis,San Francisco,Seattle,Denver,Washington,Nashville,Oklahoma City,El Paso,Boston,Portland,Las Vegas,Detroit,Memphis,Louisville,Baltimore,Milwaukee,Albuquerque,Tucson,Fresno,Sacramento,Mesa,Atlanta,Kansas City,Colorado Springs,Miami,Raleigh,Omaha,Long Beach,Virginia Beach,Oakland,Minneapolis,Tulsa,Arlington,Tampa,New Orleans,Wichita,Cleveland,Bakersfield,Aurora,Anaheim,Honolulu,Santa Ana,Riverside,Corpus Christi,Lexington,Stockton,Henderson,Saint Paul,St. Louis,Cincinnati,Pittsburgh,Greensboro,Anchorage,Plano,Lincoln,Orlando,Irvine,Newark,Durham,Chula Vista,Toledo,Fort Wayne,St. Petersburg,Laredo,Jersey City,Chandler,Madison,Lubbock,Scottsdale,Reno,Buffalo,Gilbert,Glendale,North Las Vegas,Winston-Salem,Chesapeake,Norfolk,Fremont,Garland,Irving,Hialeah,Richmond,Boise,Spokane,Baton Rouge
    """.split(separator: ",").map(String.init)
    public static let streets: [String] = """
    Main,Oak,Maple,Cedar,Pine,Elm,Washington,Lake,Hill,Park,Walnut,Sunset,Cherry,Highland,Lincoln,Jefferson,Adams,Franklin,Jackson,Madison,Monroe,Willow,Birch,Chestnut,Dogwood,Poplar,Ash,Locust,Spring,Water,Mill,Church,School,Center,Market,Broad,State,Liberty,Union,Valley,River,Forest,Meadow,Ridge,High,North,South,East,West,Green,College,University,First,Second,Third,Fourth,Fifth,Sixth,Seventh,Eighth,Ninth,Tenth,Evergreen,Sycamore,Cypress,Hawthorne,Laurel,Magnolia,Orchard,Peach,Apple,Dogwood,Acorn,Fairview,Woodland,Brookside,Creekside,Stonebridge,Hillside,Harbor,Bay,Ocean,Coastal,Mountain,Desert,Prairie,Garden,Heather,Ivy,Juniper,Redwood,Sequoia,Silver,Briar,Rolling,Sunny,Brighton,King,Queen,Prince
    """.split(separator: ",").map(String.init)
    public static let emailDomains = ["example.com", "example.net", "example.org"]
    public static let ambiguousFirst: Set<String> = Set("""
    mark grace frank jack will may june april august rose bill pat sue art amber crystal heather hazel ivy holly dawn faith hope joy summer autumn rich drew chase hunter cash sterling penny ruby pearl violet lily daisy iris jade sky river brook gene ray don van guy lane dean grant miles wade norm kelly ash cherry autumn willow robin angel sage king carter mason jordan taylor scott brooklyn genesis serenity
    """.split(separator: " ").map(String.init))
    /// First names by the gender they are usually given to, so a stand-in fits
    /// a "gender" or "title" beside it. Names given to either are in neither.
    static let female: Set<String> = Set("""
    Ana Mary Patricia Jennifer Linda Elizabeth Barbara Susan Jessica Sarah Karen Nancy Lisa Betty Margaret Sandra Ashley Kimberly Emily Donna Michelle Carol Amanda Melissa Deborah Stephanie Rebecca Laura Sharon Cynthia Kathleen Amy Shirley Angela Helen Anna Brenda Pamela Nicole Emma Samantha Katherine Christine Debra Rachel Carolyn Janet Catherine Maria Heather Diane Ruth Julie Olivia Joyce Virginia Victoria Lauren Christina Joan Evelyn Judith Megan Andrea Cheryl Hannah Jacqueline Martha Gloria Teresa Ann Sara Frances Kathryn Janice Abigail Alice Julia Judy Sophia Grace Denise Amber Doris Marilyn Danielle Beverly Isabella Theresa Diana Natalie Brittany Charlotte Marie Kayla Lori Tiffany Chloe Wanda Crystal Erica Rosie Eva Leah Ruby Lily Naomi Clara Ella Mia Zoe Lucy Nora Hazel Stella Aurora Audrey Eleanor Violet Penelope Aria Scarlett Layla Mila Claire Paisley Allison Madelyn Maya Willow Brooklyn Bella Savannah Elena Caroline Nova Emilia Everly Valentina Ivy Josephine Cora Jade Autumn Adeline Serenity Kaylee
    """.split(separator: " ").map { $0.lowercased() })
    static let male: Set<String> = Set("""
    James John Robert Michael William David Richard Joseph Thomas Charles Christopher Daniel Matthew Anthony Mark Donald Steven Paul Andrew Joshua Kenneth Kevin Brian George Timothy Ronald Edward Jason Jeffrey Ryan Jacob Gary Nicholas Eric Jonathan Stephen Larry Justin Scott Brandon Benjamin Samuel Gregory Alexander Patrick Frank Raymond Jack Dennis Jerry Tyler Aaron Jose Adam Nathan Henry Douglas Zachary Peter Kyle Walter Ethan Jeremy Harold Keith Christian Roger Noah Gerald Carl Sean Austin Arthur Lawrence Dylan Bryan Joe Billy Bruce Albert Willie Gabriel Logan Alan Juan Wayne Roy Ralph Randy Eugene Vincent Russell Louis Philip Bobby Johnny Bradley Harry Fred Howard Martin Craig Tristan Caleb Oscar Victor Edgar Frederick Stanley Leonard Adrian Ivan Colin Marcus Julian Xavier Simon Omar Liam Lucas Mason Elijah Oliver Sebastian Aiden Carter Wyatt Owen Luke Levi Isaac Lincoln Theodore Jackson Mateo Hudson Grayson Ezra Asher Leo Elias Roman Jaxon Miles Isaiah Josiah Ezekiel Cooper Jayden
    """.split(separator: " ").map { $0.lowercased() })
    public static let unambiguousFirst = Set(first.map { $0.lowercased() }).subtracting(ambiguousFirst)
    public static let firstFolded = Set(first.map { $0.lowercased() })
    public static let lastFolded = Set(last.map { $0.lowercased() })
    static let citiesFolded = Set(cities.map { $0.lowercased() })
}

/// Common English short forms of first names, both ways: "Bob" and "Robert"
/// are one person's, "Liz" and "Beth" are both "Elizabeth"'s.
enum Nicknames {
    private static let table = """
    robert:bob,bobby,rob,robbie,bert;william:bill,billy,will,willie,liam;richard:rick,ricky,rich,dick,richie;james:jim,jimmy,jamie;john:jack,johnny,jon;
    joseph:joe,joey;thomas:tom,tommy;charles:charlie,chuck,chas;michael:mike,mikey,mick;christopher:chris,kit;daniel:dan,danny;matthew:matt;anthony:tony;
    donald:don,donnie;steven:steve;stephen:steve;paul:paulie;andrew:andy,drew;kenneth:ken,kenny;edward:ed,eddie,ted,ned;timothy:tim,timmy;ronald:ron,ronnie;
    jeffrey:jeff;gregory:greg;benjamin:ben,benny;samuel:sam,sammy;alexander:alex,xander;patrick:pat,paddy;frank:frankie;francis:frank,fran;raymond:ray;
    jerome:jerry;gerald:gerry,jerry;nicholas:nick,nicky;jonathan:jon,jonny;lawrence:larry;leonard:leo,len,lenny;peter:pete;douglas:doug;zachary:zach,zack;
    walter:walt,wally;harold:hal,harry;henry:hank,harry;frederick:fred,freddie;albert:al,bert;alfred:alf,fred;arthur:art;eugene:gene;vincent:vince,vinny;
    philip:phil;phillip:phil;bradley:brad;jacob:jake;joshua:josh;nathan:nate;nathaniel:nate,nat;theodore:ted,teddy,theo;terrence:terry;gabriel:gabe;
    elizabeth:liz,lizzie,beth,betty,eliza,libby;margaret:maggie,meg,peggy,margie;katherine:kate,kathy,katie,kat;catherine:cathy,kate,katie,cat;
    kathleen:kathy,kate;jennifer:jen,jenny;patricia:pat,patty,trish;susan:sue,susie;deborah:deb,debbie;rebecca:becky,becca;jessica:jess,jessie;
    christine:chris,chrissy;christina:chris,tina;barbara:barb,babs;victoria:vicky,tori;samantha:sam,sammie;stephanie:steph;alexandra:alex,sasha;
    pamela:pam;cynthia:cindy;sandra:sandy;dorothy:dot,dottie;judith:judy;abigail:abby;amanda:mandy;kimberly:kim;nicole:nicki,nikki;caroline:carrie;
    jacqueline:jackie;theresa:terry,tess;teresa:terry,tess;josephine:jo,josie;eleanor:ellie,nell;helen:nell;valerie:val;suzanne:sue,suzy;gwendolyn:gwen
    """
    /// Every name known as the same first name: the formal one and its short forms.
    static let groups: [String: Set<String>] = {
        var groups: [String: Set<String>] = [:]
        for entry in table.split(separator: ";") {
            let halves = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard halves.count == 2 else { continue }
            let formal = String(halves[0])
            let forms = Set([formal] + halves[1].split(separator: ",").map(String.init))
            for form in forms { groups[form, default: []].formUnion(forms) }
        }
        return groups
    }()
    /// The other forms of `name`'s first name, lowercase; empty when it has none.
    static func variants(of name: String) -> Set<String> {
        let folded = name.lowercased()
        return (groups[folded] ?? []).subtracting([folded])
    }
}
