#!/bin/bash
# Builds the eval test collection: files with known content, so `fam eval evals/core.json` can score search.
# Nothing personal and no downloads: photos are macOS's own account pictures, everything else is drawn, written or
# spoken here (scripts/test-collection/collection.swift, say, textutil, sips).
#   scripts/make-test-collection.sh [dir]        default: build/testbed (deleted and made again)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TB="${1:-$REPO/build/testbed}"
TOOL="$REPO/build/testbed-tool"
mkdir -p "$REPO/build"
swiftc -O "$REPO/scripts/test-collection/collection.swift" -o "$TOOL" 2>/dev/null
rm -rf "$TB"
mkdir -p "$TB"/{img,screenshots,docs,pdf,office,id,audio,video,lang,traps}
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The first installed voice for a language ("en_IN"), e.g. "Rishi" or "Eddy (Spanish (Spain))".
voice() { say -v '?' | grep -E "  $1 " | head -1 | sed -E 's/ +[a-z]{2}_[A-Z]{2} .*//'; }
speak() { say -v "$(voice "$1")" -o "$2" "$3"; }   # speak <locale> <out.aiff> <text>

echo "== photos (macOS account pictures) =="
for dir in "/Library/User Pictures"/*/; do
  category="$(basename "$dir")"
  for f in "$dir"*.heic; do
    name="$(basename "$f" .heic)"
    sips -s format jpeg -Z 1200 "$f" --out "$TB/img/$category-$name.jpg" >/dev/null
  done
done
# Other formats: one photo kept as HEIC, one as PNG.
sips -Z 1200 "/Library/User Pictures/Flowers/Lotus.heic" --out "$TB/img/Flowers-Lotus.heic" >/dev/null && rm "$TB/img/Flowers-Lotus.jpg"
sips -s format png -Z 1200 "/Library/User Pictures/Sports/Tennis.heic" --out "$TB/img/Sports-Tennis.png" >/dev/null && rm "$TB/img/Sports-Tennis.jpg"

echo "== screenshots =="
shot() { "$TOOL" screenshot "$TB/screenshots/$1" "${@:2}"; xattr -w com.apple.metadata:kMDItemIsScreenCapture 1 "$TB/screenshots/$1"; }
shot "Screenshot 2026-10-01 at 10.12.33.png" "Payments" "Payment declined" "Your card ending 4242 was declined by the issuer." "Error code: PAY-4021" "Try another payment method."
shot "Screenshot 2026-10-03 at 08.40.10.png" "Weather" "Bengaluru" "Thunderstorms expected at 4 PM" "Chance of rain: 80%" "Temperature: 23°C"
shot "Screenshot 2026-10-05 at 19.02.55.png" "Calendar" "Dentist appointment" "Dr. Mehta, Smile Dental Clinic" "Tuesday 14 November, 10:30 AM" "Bring previous X-rays"
shot "Screenshot 2026-10-07 at 22.15.03.png" "Terminal" "ModuleNotFoundError: No module named 'pandas'" "Traceback (most recent call last):" "File \"analysis.py\", line 3, in <module>" "import pandas as pd"
shot "Screenshot 2026-10-09 at 06.55.41.png" "Boarding pass" "IndiGo 6E 2134" "Bengaluru BLR to Delhi DEL" "Gate 12 · Boarding 07:45" "Seat 14C"
# Near-duplicates of the two above: another flight, another doctor.
shot "Screenshot 2026-10-12 at 17.20.08.png" "Boarding pass" "Air India AI 504" "Delhi DEL to Mumbai BOM" "Gate 3 · Boarding 18:10" "Seat 22A"
shot "Screenshot 2026-10-13 at 09.05.47.png" "Calendar" "Eye check-up" "Dr. Rao, Vision Care" "Friday 17 November, 4:00 PM" "Bring your current glasses"
shot "Screenshot 2026-10-11 at 13.30.00.png" "Wi-Fi" "Wi-Fi: HomeMesh-5G" "Connected · Secured (WPA3)" "IP address 192.168.1.24" "Router 192.168.1.1"

echo "== documents =="
html() { printf '<html><body>%s</body></html>' "$1" > "$WORK/doc.html"; textutil -convert "$2" "$WORK/doc.html" -output "$3"; }
html "<h1>Apartment Lease Agreement</h1><p>Section 12. Pets. Tenants may keep one cat or one small dog under 10 kg with a refundable pet deposit of Rs 15,000. Reptiles and birds are not allowed.</p><p>Section 13. Rent. Rent of Rs 28,000 is due on the 5th of each month by bank transfer.</p>" docx "$TB/docs/lease.docx"
html "<h1>Lisbon trip ideas</h1><p>Take tram 28 through Alfama, eat pastel de nata in Belem, and watch the sunset from Miradouro da Senhora do Monte. Book the Sintra day trip early because Pena Palace tickets sell out.</p>" rtf "$TB/docs/lisbon-trip.rtf"
html "<h1>Car insurance</h1><p>Policy number MH-PL-778812. Comprehensive cover for the Honda City. The policy renews on 3 March 2027 and the no-claim bonus is 35 percent.</p>" odt "$TB/docs/car-insurance.odt"
cat > "$TB/docs/offer-letter.html" <<'EOF'
<html><body><h1>Offer of employment</h1><p>We are pleased to offer you the role of Senior Data Engineer. Your annual compensation will be Rs 32,00,000 fixed plus a performance bonus of up to 15 percent. Your joining date is 2 January 2027.</p></body></html>
EOF
cat > "$TB/docs/masala-chai.md" <<'EOF'
# Masala chai
Boil one cup of water with crushed ginger, two cardamom pods, a small piece of cinnamon and two cloves. Add two teaspoons of black tea and simmer for two minutes, then pour in a cup of milk and sugar to taste. Bring it to a boil once more and strain.
EOF
cat > "$TB/docs/meeting-notes.txt" <<'EOF'
Q3 planning meeting. Decision: we will migrate the billing service from MySQL to Postgres before the holiday freeze. Owner: Priya. Risks: downtime during the cutover, so we need a rollback plan and a dry run in staging.
EOF
cat > "$TB/docs/gym-membership.txt" <<'EOF'
FitLife gym membership terms. Monthly plan, Rs 2,500 per month. To cancel your membership you must give 30 days written notice at the front desk or by email. Freezing the membership is allowed for up to two months a year.
EOF
cat > "$TB/docs/laptop-warranty.md" <<'EOF'
# Laptop warranty
MacBook Pro 14-inch, serial C02XK1ABCD. AppleCare+ coverage is active until 18 June 2027. Covers accidental damage twice a year with a service fee.
EOF
cat > "$TB/docs/router-notes.txt" <<'EOF'
Home network notes. The router admin password was reset in March. WiFi channel 36 works best for the office. If the connection drops, restart the modem first, then the mesh nodes. ISP support ticket number INC-48213.
EOF
# Near-duplicates: a second insurance policy, a second drink recipe.
cat > "$TB/docs/health-insurance.txt" <<'EOF'
Health insurance. Policy number HL-55821, family floater for four members. Sum insured Rs 10,00,000. The policy renews on 1 August 2027. Covers hospitalisation, day-care procedures and ambulance charges.
EOF
cat > "$TB/docs/cold-brew-coffee.md" <<'EOF'
# Cold brew coffee
Coarsely grind 100 g of coffee beans, stir into one litre of cold water and leave it in the fridge for 16 hours. Strain through a paper filter, then serve over ice with milk.
EOF
cat > "$TB/docs/blood-test-report.txt" <<'EOF'
Laboratory report. Vitamin D (25-OH): 14 ng/mL, low, reference range 30 to 100. Vitamin B12: 410 pg/mL, normal. Haemoglobin: 13.8 g/dL, normal. Advice: vitamin D supplementation and recheck in three months.
EOF

echo "== PDFs =="
"$TOOL" pdf "$TB/pdf/handbook.pdf" \
  "Employee handbook. Welcome to the company. This handbook explains our policies on working hours, leave, travel and conduct." \
  "Working hours. The standard working week is 40 hours, Monday to Friday. Core hours are 11 AM to 4 PM." \
  "Annual leave. Every employee gets 24 days of paid annual leave per year, which can be carried over up to 10 days." \
  "Sick leave. Up to 12 days of paid sick leave a year. A doctor's note is needed for more than two days in a row." \
  "Parental leave. Birthing parents receive 26 weeks of fully paid parental leave. Other parents receive 12 weeks. Leave can start up to four weeks before the due date." \
  "Travel and expenses. Book travel through the company portal. Submit receipts within 30 days to claim reimbursement of travel expenses, meals and hotels." \
  "Remote work. Employees may work from home up to three days a week with their manager's agreement. The company pays for a home office chair and monitor." \
  "Code of conduct. Treat colleagues with respect. Report concerns to HR or the ethics hotline."
"$TOOL" pdf "$TB/pdf/annual-report.pdf" \
  "Annual report 2026. A year of steady growth across all regions." \
  "Letter from the CEO. Our teams delivered record customer satisfaction." \
  "Regional results. Revenue in the Asia Pacific region grew 18 percent, led by India and Indonesia. Europe grew 6 percent." \
  "Products. We launched three new products and retired two older ones." \
  "Sustainability. We commit to net zero carbon emissions by 2035 and cut emissions from our offices by 40 percent this year." \
  "Outlook. We expect growth to continue next year."
"$TOOL" pdf "$TB/pdf/degree-certificate.pdf" "University of Testing. Provisional Degree Certificate. This is to certify that the candidate has passed the Bachelor of Science examination with first class. Registration No: 21/BSC/0456. Date of issue: 15 July 2024."
"$TOOL" pdf "$TB/pdf/invoice-2026-031.pdf" "Invoice INV-2026-031. Billed to: Example Labs. Website hosting, annual plan: Rs 18,000. GST 18 percent: Rs 3,240. Total due: Rs 21,240 by 30 November 2026."
"$TOOL" scan "$TB/pdf/scan-receipt.pdf" "FRESH MART" "Milk 2 x 64.00" "Bread 1 x 45.00" "Eggs 12 x 7.50" "Rice 5 kg 540.00" "Paneer 1 x 120.00" "TOTAL Rs 1,284.50" "Thank you for shopping with us"

echo "== slides and spreadsheet =="
python3 -I - "$TB/office" <<'EOF'
import sys, zipfile
d = sys.argv[1]
def z(name, files):
    with zipfile.ZipFile(f"{d}/{name}", "w") as f:
        for k, v in files.items(): f.writestr(k, v)
slides = ["2027 Product Roadmap", "Q1: redesign onboarding and cut signup time in half",
          "Q2: launch the mobile app in Brazil and Mexico. Hire three Android engineers.", "Q3: enterprise single sign-on"]
z("roadmap.pptx", {f"ppt/slides/slide{i + 1}.xml": f"<p:sld><a:t>{t}</a:t></p:sld>" for i, t in enumerate(slides)})
z("budget.xlsx", {"xl/workbook.xml": '<workbook><sheet name="Marketing budget 2027"/></workbook>',
                  "xl/sharedStrings.xml": "<sst><si><t>Facebook ads</t></si><si><t>Conference sponsorship, Web Summit</t></si><si><t>Influencer campaign</t></si></sst>"})
EOF

echo "== ID documents =="
"$TOOL" card "$TB/id/IMG_4821.jpg" "INCOME TAX DEPARTMENT" "GOVT. OF INDIA" "Permanent Account Number Card" "QWERT6789K" "Name: TEST PERSON" "Date of Birth: 01/01/1990"

echo "== audio =="
speak en_US "$WORK/a1.aiff" "Today we start in the kitchen. To make a good tomato pasta, boil salted water, cook the spaghetti for nine minutes, and save a cup of the starchy water. Fry garlic in olive oil, add crushed tomatoes and basil, then toss the pasta with the sauce."
speak en_US "$WORK/a2.aiff" "Next, let's talk about sleep. Most adults need seven to nine hours of sleep every night. Keep your bedroom cool and dark, avoid screens for an hour before bed, and stop drinking coffee after lunch, because caffeine ruins deep sleep."
speak en_US "$WORK/a3.aiff" "Finally, money. If you are new to investing, a low cost index fund is a simple place to start. Invest a fixed amount every month, ignore the daily news, and think in decades rather than days."
"$TOOL" concat "$TB/audio/podcast.m4a" 30 "$WORK/a1.aiff" "$WORK/a2.aiff" "$WORK/a3.aiff"   # topics at 0, 30 and 60 s
# Continuous recordings whose topics change at uneven moments: where a 30 s window mixes two of them. Each topic
# runs about 20-25 s, back to back; <file>.segments.json says where each starts and ends.
speak en_GB "$WORK/r1.aiff" "Good morning, and welcome to the show. First, the weather. Heavy rain is expected on Thursday, with strong winds along the coast in the afternoon, so take an umbrella if you are heading out. Temperatures stay mild, and it should clear up nicely by the weekend."
speak en_GB "$WORK/r2.aiff" "In football, our local team, the City Rovers, won their match last night by two goals to one. They were a goal down at half time, but the captain scored a late winner in the final minute, and the crowd went wild. They now sit third in the league."
speak en_GB "$WORK/r3.aiff" "Now the traffic. The northern highway is closed for repairs until Monday morning, after a crack was found in the bridge. Drivers should use the ring road instead, and expect long delays near the airport during the evening rush hour."
speak en_GB "$WORK/r4.aiff" "Some good news for food lovers. A new bakery opens on Market Street this Saturday. It will sell sourdough bread, croissants and cinnamon rolls, baked fresh every morning, and the first hundred customers get a free coffee."
speak en_GB "$WORK/r5.aiff" "The city library is changing its opening hours. From next month it will stay open until ten in the evening on weekdays, and it is adding a quiet study room on the second floor, which students can book online."
speak en_GB "$WORK/r6.aiff" "And finally, music. Tickets for the summer jazz festival go on sale on Friday morning at nine. Last year they sold out in under an hour, so set an alarm. That is all for today, thank you for listening."
"$TOOL" concat "$TB/audio/radio-show.m4a" auto "$WORK/r1.aiff" "$WORK/r2.aiff" "$WORK/r3.aiff" "$WORK/r4.aiff" "$WORK/r5.aiff" "$WORK/r6.aiff"
speak en_IN "$WORK/m1.aiff" "Okay, let's start. First item on the agenda is hiring. We will open two positions for product designers this quarter. The job descriptions are ready, and interviews start next week, so please share the posting with anyone you know."
speak en_IN "$WORK/m2.aiff" "Second item is the office move. We are moving to the new office in Koramangala in March. Please pack your desks by the end of February, and the movers will take care of the monitors and chairs."
speak en_IN "$WORK/m3.aiff" "Third item, customer churn. It went up to four percent last month. Most of it is small accounts leaving after the price change, so the sales team will call each of them this week to understand why."
speak en_IN "$WORK/m4.aiff" "Last item is laptops. From now on every laptop will be replaced every three years, and the old ones go to the donation programme. If yours is older than that, raise a ticket with IT."
"$TOOL" concat "$TB/audio/team-meeting.m4a" auto "$WORK/m1.aiff" "$WORK/m2.aiff" "$WORK/m3.aiff" "$WORK/m4.aiff"
speak en_GB "$WORK/memo.aiff" "Reminder to self: renew the car registration before Friday, and buy a birthday present for Ananya."
"$TOOL" concat "$TB/audio/voice-memo.m4a" 12 "$WORK/memo.aiff"
speak en_IN "$WORK/standup.aiff" "Good morning team. Quick update on the quarterly targets. Sales in the south region are ahead of plan, the Chennai warehouse goes live next week, and we still need two more data engineers."
"$TOOL" concat "$TB/audio/standup-recording.m4a" 20 "$WORK/standup.aiff"

echo "== video =="
P="/Library/User Pictures"
speak en_GB "$WORK/zoo.aiff" "Welcome to our day at the zoo. We walked around all morning and the children loved every minute of it."
sips -s format jpeg "$P/Animals/Penguin.heic" --out "$WORK/penguin.jpg" >/dev/null
sips -s format jpeg "$P/Animals/Zebra.heic" --out "$WORK/zebra.jpg" >/dev/null
sips -s format jpeg "$P/Animals/Parrot.heic" --out "$WORK/parrot.jpg" >/dev/null
"$TOOL" concat "$WORK/zoo.m4a" 18 "$WORK/zoo.aiff"   # AVFoundation won't add AIFF to a movie: m4a first
"$TOOL" video "$TB/video/zoo-trip.mov" "$WORK/zoo.m4a" "$WORK/penguin.jpg:6" "$WORK/zebra.jpg:6" "$WORK/parrot.jpg:6"   # 0-6, 6-12, 12-18 s
speak en_US "$WORK/boat.aiff" "Here we are on the boat. Look at the dolphins jumping right next to us. The ocean is so calm today."
sips -s format jpeg "$P/Nature/Sandollar.heic" --out "$WORK/beach.jpg" >/dev/null
"$TOOL" concat "$WORK/boat.m4a" 12 "$WORK/boat.aiff"
"$TOOL" video "$TB/video/boat-trip.mov" "$WORK/boat.m4a" "$WORK/beach.jpg:12"

echo "== other languages =="
cat > "$TB/lang/hi-dal-recipe.txt" <<'EOF'
मसूर दाल बनाने की विधि: एक कप दाल को धोकर तीन कप पानी, हल्दी और नमक के साथ कुकर में तीन सीटी तक पकाएं। एक पैन में घी गरम करें, उसमें जीरा, लहसुन और हरी मिर्च डालें और यह तड़का दाल में मिला दें। ऊपर से धनिया डालकर चावल के साथ परोसें।
EOF
cat > "$TB/lang/ja-kyoto-travel.txt" <<'EOF'
京都旅行メモ：清水寺、伏見稲荷大社、金閣寺を訪れる予定。嵐山の竹林は混む前の朝早くに行くのがおすすめ。夜は祇園を散歩する。
EOF
cat > "$TB/lang/de-rechnung.txt" <<'EOF'
Rechnung Nr. 2026-118. Leistung: jährliche Wartung der Gasheizung, Reinigung des Brenners und Prüfung der Abgaswerte. Betrag: 189,00 Euro inklusive Mehrwertsteuer. Zahlbar innerhalb von 14 Tagen.
EOF
cat > "$TB/lang/ta-school-notice.txt" <<'EOF'
பள்ளி அறிவிப்பு: தீபாவளி பண்டிகையை முன்னிட்டு பள்ளி அக்டோபர் 30 முதல் நவம்பர் 3 வரை மூடப்படும். நவம்பர் 4 அன்று வகுப்புகள் வழக்கம் போல் தொடங்கும்.
EOF
cat > "$TB/lang/es-contrato-alquiler.txt" <<'EOF'
Contrato de alquiler. Cláusula 7: si el inquilino paga el alquiler con más de cinco días de retraso, deberá pagar una multa del diez por ciento del importe mensual. Cláusula 8: el depósito se devolverá al final del contrato.
EOF
speak hi_IN "$WORK/hi.aiff" "इस साल मानसून जल्दी आया है। मुंबई में भारी बारिश हो रही है और कई सड़कों पर पानी भर गया है। लोगों को घर पर रहने की सलाह दी गई है।"
"$TOOL" concat "$TB/lang/hi-monsoon.m4a" 20 "$WORK/hi.aiff"
speak es_ES "$WORK/es.aiff" "El partido de fútbol de anoche fue increíble. El Real Madrid ganó tres a uno, con dos goles en el segundo tiempo."
"$TOOL" concat "$TB/lang/es-futbol.m4a" 15 "$WORK/es.aiff"

echo "== traps =="
T="$TB/traps"
mkdir -p "$T/duplicates" "$T/.hidden" "$T/node_modules/pkg" "$T/Fake.app/Contents/Resources" "$T/icons" "$T/MyProject/build"
cp "$TB/img/Animals-Penguin.jpg" "$T/duplicates/penguin.jpg"
cp "$TB/img/Animals-Penguin.jpg" "$T/duplicates/penguin copy.jpg"
cp "$TB/img/Flowers-Sunflower.jpg" "$T/Café menü — 日本語.jpg"            # odd characters in the name
cp "$TB/img/Nature-Leaf.jpg" "$T/.hidden/leaf.jpg"                         # hidden folder: never read
cp "$TB/img/Animals-Eagle.jpg" "$T/node_modules/pkg/eagle.jpg"             # dependencies: never read
cp "$TB/img/Fun-Medal.jpg" "$T/Fake.app/Contents/Resources/medal.jpg"      # app bundle: never read
sips -Z 32 "$TB/img/Sports-Target.jpg" --out "$T/icons/target-32.png" >/dev/null   # icon: too small to read
echo '{"name": "my-project"}' > "$T/MyProject/package.json"
cp "$TB/img/Animals-Owl.jpg" "$T/MyProject/build/owl.jpg"                  # build output in a code project: never read
# Privacy: never read, by name (the first three) or by content (the last two, under ordinary names).
mkdir -p "$T/private"
printf 'Bank login: user anand.k, password Sunflower#2026\nEmail password: Blue-Kettle-77\n' > "$T/private/my passwords.txt"
printf '[default]\naws_access_key_id = AKIAEXAMPLEKEY123456\naws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n' > "$T/private/credentials.txt"
printf 'Recovery codes for my email account: 4821-7730, 1937-5562, 8840-2219\n' > "$T/private/recovery-codes.md"
printf 'Server notes for the deploy box.\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----\n' > "$T/private/server notes.txt"
printf 'Config for the reporting job. aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY region = ap-south-1\n' > "$T/private/job-config.md"
python3 -I -c "
import random; random.seed(7)
print('\n'.join(','.join(str(random.randint(0, 99999)) for _ in range(8)) for _ in range(400)))" > "$T/numbers.csv"   # numbers only

echo "Built $TB: $(find "$TB" -type f | wc -l | tr -d ' ') files"
