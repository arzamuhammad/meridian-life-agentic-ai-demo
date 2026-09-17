# Meridian Life — Demo Sales Agentic AI di Snowflake

Demo lengkap dan bisa diulang tentang **agentic AI untuk penjualan asuransi jiwa**, dibangun
sepenuhnya di dalam Snowflake. Anda menjalankan serangkaian script, dan hasil akhirnya: data
sintetis, tujuh model machine learning, satu Cortex Agent yang menjawab pertanyaan bisnis dengan
bahasa manusia, dan dashboard Streamlit tujuh halaman.

**Meridian Life adalah perusahaan fiktif. Seluruh data 100% sintetis. Tidak ada PII nyata.**
Mata uang Rupiah (IDR); semua label dalam bahasa Inggris.

> **Baru mengenal Snowflake atau bukan orang asuransi?** README ini tidak mengasumsikan
> keduanya. Setiap langkah menjelaskan apa yang dijalankan, apa yang seharusnya Anda lihat, dan
> cara memastikan hasilnya benar. Kalau ada yang gagal, bagian
> [Troubleshooting](#troubleshooting) memuat kegagalan yang benar-benar kami alami saat
> membangunnya.
>
> **English version:** [README.md](./README.md).

---

## Daftar Isi

1. [Apa yang Anda Dapatkan](#1-apa-yang-anda-dapatkan)
2. [Masalah Bisnis yang Dijawab](#2-masalah-bisnis-yang-dijawab)
3. [Prasyarat](#3-prasyarat)
4. [Langkah 0 — Menyalin repo ini ke Snowflake](#langkah-0--menyalin-repo-ini-ke-snowflake)
5. [Langkah 1 — Setup dan Data Sintetis](#langkah-1--setup-dan-data-sintetis)
6. [Langkah 2 — Model Machine Learning](#langkah-2--model-machine-learning)
7. [Langkah 3 — Dokumen Produk dan Cortex Search](#langkah-3--dokumen-produk-dan-cortex-search)
8. [Langkah 4 — Semantic View](#langkah-4--semantic-view)
9. [Langkah 5 — Cortex Agent](#langkah-5--cortex-agent)
10. [Langkah 6 — Dashboard Streamlit](#langkah-6--dashboard-streamlit)
11. [Langkah 7 — Closed Loop](#langkah-7--closed-loop)
12. [Cara Memakai Demo](#cara-memakai-demo)
13. [Arsitektur dan Keputusan Desain](#arsitektur-dan-keputusan-desain)
14. [Troubleshooting](#troubleshooting)
15. [Biaya dan Pembersihan](#biaya-dan-pembersihan)
16. [Struktur Repository](#struktur-repository)
17. [Lampiran — Memakai CLI](#lampiran--memakai-cli)

---

## 1. Apa yang Anda Dapatkan

Setelah kurang lebih **30 menit runtime** (sebagian besar hanya menunggu), akun Snowflake Anda
akan berisi:

| Komponen | Detail |
|----------|--------|
| **Data sintetis** | 14 tabel, ~300rb baris: 23 cabang, 1.500 agen, 4.400 nasabah, 70 produk, 7.400 polis |
| **7 model ML** | Prediksi lapse (XGBoost), forecast pendapatan, skoring agen, next best action, customer lifetime value, deteksi anomali, aturan cross-sell |
| **24 brosur produk** | Teks dibuat AI → PDF ber-branding → di-parsing → di-chunk → bisa dicari |
| **Cortex Search** | `MERIDIAN_PRODUCT_SEARCH`, 164 chunk dari 24 produk |
| **Semantic View** | `MERIDIAN_SALES_INTELLIGENCE`: 22 tabel, 40 metrik, 12 verified query |
| **Cortex Agent** | `MERIDIAN_COMMAND_CENTER_AGENT`, 15 tool termasuk web search dan pembuat PPTX |
| **App Streamlit** | `MERIDIAN_COMMAND_CENTER_DASHBOARD`, 7 halaman |
| **Closed loop** | Tabel feedback dan outcome rekomendasi, sehingga efektivitas model bisa diukur |

Angka utama dari buku yang ter-generate: **Rp 49,5 miliar** premi tahun pertama (FYAP),
**17 dari 23 cabang di bawah target** pada 2025, cabang terburuk Jember di **44,0%** dari
target, dan **6.002 polis** ter-skor risiko lapse.

---

## 2. Masalah Bisnis yang Dijawab

Kalau Anda bukan orang asuransi, ini masalahnya dalam bahasa sederhana.

Perusahaan asuransi jiwa menjual polis melalui **agen** yang bekerja di **cabang**. Kantor pusat
menetapkan **target** pendapatan per cabang. Setiap bulan manajemen menanyakan empat hal:

1. **Apakah kita sesuai rencana?** Cabang mana yang di bawah target, dan selisihnya berapa?
2. **Kenapa kita tertinggal?** Karena agennya kurang, bauran produknya salah, atau nasabahnya
   pergi?
3. **Siapa yang akan pergi?** Polis yang berhenti dibayar disebut **lapse**. Memprediksinya
   memungkinkan agen menelepon nasabah **sebelum** itu terjadi.
4. **Hari ini kita harus apa?** Bukan laporan — tapi daftar tindakan konkret untuk orang
   tertentu.

Dashboard biasa hanya menjawab pertanyaan 1. Demo ini menjawab keempatnya, dan menutup loop-nya
dengan mencatat apakah tindakan yang direkomendasikan benar-benar berhasil.

**Istilah asuransi yang dipakai di repo ini:**

| Istilah | Artinya |
|---------|---------|
| **FYAP / FYP** | First-Year Annualised Premium. Angka penjualan utama di industri ini |
| **Lapse** | Nasabah berhenti membayar; polis mati. Sumber kebocoran pendapatan utama |
| **Persistency** | Persentase polis yang masih dibayar setelah N bulan |
| **Masa tenggang** | Jumlah hari setelah pembayaran terlewat sebelum polis lapse |
| **Rider** | Manfaat tambahan opsional yang dilekatkan ke polis dasar |
| **NBA** | Next Best Action — satu hal paling bernilai yang harus dilakukan agen berikutnya |
| **CLV** | Customer Lifetime Value — nilai total yang diharapkan dari seorang nasabah |
| **Cross-sell** | Menjual produk tambahan ke nasabah yang sudah ada |
| **Activation rate** | Persentase agen yang benar-benar menjual sesuatu di satu periode |

---

## 3. Prasyarat

### 3.1 Akun Snowflake

- Akun Snowflake **edisi Enterprise atau lebih tinggi** dengan **Cortex AI aktif**
- Role **ACCOUNTADMIN** (script membuat database, warehouse, dan agent)
- Sekitar **2 GB** storage dan beberapa kredit compute

### 3.2 Cross-region inference — WAJIB

**Ini penyebab kegagalan build yang paling sering terjadi.** Snowflake Cortex tidak menyediakan
semua model di semua region. Demo ini memakai `claude-4-sonnet`, model embedding
`arctic-embed-l-v2.0`, dan `AI_PARSE_DOCUMENT`. Di banyak region — termasuk
**AWS Asia Pacific (Jakarta), `ap-southeast-3`** — sebagian model itu tidak tersedia secara
lokal, dan semua panggilan AI akan gagal dengan error seperti:

```
unknown model "claude-4-sonnet"
```

Aktifkan cross-region inference **sebelum mulai**:

```sql
USE ROLE ACCOUNTADMIN;

ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- Verifikasi: kolom VALUE harus ANY_REGION, bukan DISABLED
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

Lalu pastikan model-nya benar-benar menjawab:

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-4-sonnet', 'Reply with the single word OK');
```

Kalau hasilnya `OK`, Anda siap. Kalau error, **jangan lanjut** — semua langkah AI akan gagal.

> **Apa arti setting ini, dan kenapa tim security Anda perlu tahu.** Dengan `ANY_REGION`,
> permintaan Cortex yang tidak bisa dilayani di region Anda akan diproses di region lain.
> Inference-nya stateless dan Snowflake tidak menyimpan prompt Anda untuk training, tetapi
> permintaan itu memang keluar dari region Anda. Sebagian organisasi membatasinya ke region
> tertentu alih-alih `ANY_REGION` — misalnya `'AWS_US'`. Periksa dulu kebijakan data residency
> Anda sebelum mengaktifkannya di akun produksi. Untuk akun demo, `ANY_REGION` aman.

### 3.3 Yang perlu Anda pasang di komputer

**Tidak ada.** Cukup browser.

Tidak ada CLI yang perlu diinstal, tidak ada environment Python yang perlu dibuat, tidak ada
paket yang perlu diunduh. Snowflake menyalin repository ini ke dalam akun Anda, dan Anda
menjalankan semuanya dari Snowsight — SQL lewat editor Workspace, dan dua langkah Python sebagai
Snowflake Notebook.

> Kalau Anda lebih suka bekerja dari terminal, jalur Snowflake CLI tetap berfungsi dan
> didokumentasikan di [Lampiran — Memakai CLI](#lampiran--memakai-cli).

### 3.4 Opsional: web search untuk agent

Salah satu dari 15 tool agent adalah web search, dipakai untuk membandingkan buku sintetis ini
dengan benchmark industri publik. Kalau akun Anda belum mengaktifkannya, 14 tool lainnya tetap
berfungsi.

Aktifkan di Snowsight: **AI & ML → Agents → Settings → Web access**.

---

## Langkah 0 — Menyalin repo ini ke Snowflake

**Waktu: 10 menit. Tanpa menulis kode.**

Alih-alih mengunduh repo ke laptop, Anda meminta Snowflake menyambungkan diri ke GitHub dan
menyalinnya ke dalam akun Anda. Hasilnya disebut **Workspace** — tempat kerja berisi folder dan
file di dalam Snowflake, mirip sebuah project di editor.

### 0a — Buka Workspaces

1. Di menu kiri, pilih **Projects** → **Workspaces**
2. Klik tombol **+** di kanan atas
3. Pilih **Git Workspace**

> Kalau menu yang muncul bertuliskan **From Git repository**, itu hal yang sama. Label tombol
> bisa berbeda sedikit antar rilis Snowsight.

### 0b — Isi form

**Repository URL**

| Field | Isi dengan |
|---|---|
| Repository URL | `https://github.com/arzamuhammad/meridian-life-agentic-ai-demo` |

**API Integration**

Snowflake perlu izin untuk berbicara dengan GitHub. Izin ini bernama **API integration**, dan
bisa dibuat **langsung dari dalam form ini** — tanpa menulis SQL.

Klik dropdown **API Integration**:

- **Kalau sudah ada pilihan** yang mencakup github.com, pilih saja lalu lanjut.
- **Kalau kosong**, klik **+ Create a new API integration** dan isi:

| Field | Isi dengan | Catatan |
|---|---|---|
| Integration name | `GITHUB_API_INT` | **Harus HURUF BESAR semua.** Huruf kecil akan ditolak |
| Allowed domain | `github.com` | Cukup domainnya, tanpa `https://` |

Klik **Create**. Integration ini hanya perlu dibuat **sekali per akun** — orang berikutnya cukup
memilihnya dari dropdown.

> **Apakah ini sama dengan External Access Integration? Bukan.** Namanya mirip tapi fungsinya
> berbeda. **API integration** dipakai Snowflake untuk berbicara dengan penyedia Git.
> **External Access Integration** dipakai kalau *kode Anda* perlu menjangkau internet, misalnya
> `pip install`. Demo ini hanya butuh yang pertama.

**Workspace name — jangan diubah**

| Field | Nilainya |
|---|---|
| Workspace name | `meridian-life-agentic-ai-demo` |

Snowsight mengisinya otomatis dari nama repo. **Biarkan apa adanya.** File
`07_streamlit/71_deploy_streamlit.sql` menyebut nama ini secara literal, dan namanya bersifat
*case-sensitive*. Kalau Anda menggantinya, Anda harus mengeditnya juga di file itu.

**Metode autentikasi**

Pilih **Public repository**, lalu klik **Create**. Repo ini publik, jadi tidak perlu token.
Konsekuensinya Anda **tidak bisa** mengirim perubahan balik ke GitHub — dan untuk belajar itu
justru aman: Anda bebas bereksperimen tanpa takut merusak apa pun.

### 0c — Pastikan berhasil

Panel kiri harus menampilkan:

```
01_setup/   02_generate_data/   03_ml/   04_search/
05_semantic_view/   06_agent/   07_streamlit/   08_closed_loop/   docs/
LICENSE   README.md   README-IND.md
```

Klik `01_setup/` lalu `01_setup.sql`. File-nya harus terbuka dan bisa dibaca.

### 0d — Pilih warehouse

Di kanan atas editor ada pemilih warehouse. Pilih warehouse apa pun yang tersedia untuk
sekarang. `01_setup.sql` akan membuat `GEN2_SMALL` di langkah berikutnya; setelah itu pindah ke
sana.

---

## Cara menjalankan file SQL — baca sekali saja

Semua file `.sql` di repo ini dijalankan dengan cara yang sama, dan inilah bagian yang paling
sering ditanyakan.

**Jangan jalankan seluruh file sekaligus.** Jalankan **satu statement demi satu**:

1. Buka file-nya di editor Workspace
2. Letakkan kursor di dalam statement pertama
3. Tekan **Cmd+Enter** (macOS) atau **Ctrl+Enter** (Windows)
4. Baca hasilnya, lalu pindahkan kursor ke statement berikutnya dan ulangi

Kenapa satu per satu? Karena setiap langkah memberi tahu Anda sesuatu. Kalau statement ke-4
gagal, Anda ingin langsung melihatnya dengan statement 1–3 sudah diterapkan — bukan mencarinya
di tumpukan output. Beberapa file juga mencetak hasil verifikasi yang memang harus Anda baca
sebelum lanjut.

> Satu statement berakhir di tanda titik koma `;`. Snowsight menyorot statement tempat kursor
> Anda berada, jadi Anda selalu tahu apa yang akan dijalankan.

---

## Langkah 1 — Setup dan Data Sintetis

Membuat warehouse, database, schema, stage, dan seluruh 14 tabel data.

Buka tiap file di Workspace dan jalankan statement demi statement, dalam urutan ini:

```
01_setup/01_setup.sql
02_generate_data/20_gen_helpers.sql
02_generate_data/21_dimensions.sql
02_generate_data/22_fact_policy.sql
02_generate_data/23_fact_policy_children.sql
02_generate_data/24_fact_agent.sql
02_generate_data/25_fact_target_crm.sql
02_generate_data/26_helper_views.sql
```

> Setelah `01_setup.sql` selesai, ganti pemilih warehouse di kanan atas ke **GEN2_SMALL** —
> file itu baru saja membuatnya.
>
> Beberapa statement di `22`, `23`, dan `24` butuh 30–60 detik. Itu normal; mereka membuat
> ratusan ribu baris. Tunggu satu selesai sebelum memulai berikutnya.

**Runtime**: sekitar 4 menit total.

### Kenapa datanya deterministik

Generator ini **tidak pernah** memakai `RANDOM()`. Ia memakai user-defined function berbasis
hash — `RND(key, salt)`, `RNDI(...)`, `RNDN(...)` — yang dikunci pada business key setiap baris.
Jalankan sepuluh kali, hasilnya identik byte per byte. Ini penting karena model ML, verified
query di semantic view, dan skrip demo semuanya merujuk angka spesifik.

### Checkpoint 1 — verifikasi sebelum lanjut

```
02_generate_data/27_verify_stop1.sql
```

Jumlah baris yang diharapkan:

| Tabel | Baris |
|-------|-------|
| DIM_BRANCH | 23 |
| DIM_AGENT | 1.500 |
| DIM_CUSTOMER | 4.400 |
| DIM_PRODUCT | 70 |
| FACT_POLICY | 7.400 |
| FACT_POLICY_PAYMENT | 44.522 |
| FACT_POLICY_RIDER | 11.046 |
| FACT_CLAIMS | 2.176 |
| FACT_AGENT_PRODUCTION | 12.420 |
| FACT_AGENT_ACTIVITY | 100.000 |
| FACT_AGENT_APPS_BEHAVIOR | 100.000 |
| FACT_TRAINING | 3.454 |
| FACT_BRANCH_TARGET | 66 |
| FACT_CRM_TICKETS | 2.453 |

Semua pemeriksaan integritas foreign key harus mengembalikan **0 orphan**. Kalau ada jumlah yang
jauh berbeda atau ada pemeriksaan yang mengembalikan baris, berhenti dan jalankan ulang dari
`21_dimensions.sql` — langkah berikutnya bergantung pada data ini persis.

### Pola yang sengaja ditanam di data

Ini yang nanti "ditemukan" oleh model. Mengetahuinya membantu Anda memastikan model benar-benar
bekerja, bukan menebak.

| Pola | Bentuknya |
|------|-----------|
| Lonjakan lapse bulan ke-13 | Hazard 9,59% di bulan 13 = **12,6× baseline**; bulan 25 = 3,69% = 4,9× |
| Frekuensi bayar memengaruhi lapse | Tahunan 4,87% < Semesteran 8,64% < Kuartalan 12,23% < Bulanan 15,05% |
| Sebaran pencapaian cabang | Jember 44,0% (terburuk) sampai Surabaya 131,0% (terbaik) |
| Afinitas cross-sell | Savings → Retirement lift 2,98; UnitLink → Education 1,58 |
| Guncangan produksi | 3 lonjakan dan 3 penurunan ditanam di bulan-cabang tertentu |
| Layanan berkorelasi dengan risiko | 55,4% tiket CRM berada di polis yang berisiko lapse |

> **Penting soal jumlah lapse.** Angka **hitungan** lapse mentah membuat lonjakan bulan ke-25
> terlihat lebih kecil dari kenyataan karena *right-censoring* — banyak polis belum mencapai
> bulan 25. Selalu pakai **hazard** (lapse ÷ polis yang berisiko), yang itulah yang dihitung
> panel di Langkah 2.

---

## Langkah 2 — Model Machine Learning

Tujuh model. Enam murni SQL. Hanya M1 yang butuh Python, dan itu dijalankan sebagai
**Snowflake Notebook** — tetap tanpa instalasi lokal.

Jalankan dalam urutan ini:

| Urutan | File | Cara menjalankan |
|--------|------|------------------|
| 1 | `03_ml/31_m1_lapse_panel.sql` | Editor Workspace, statement demi statement |
| 2 | `03_ml/32_m1_train_xgboost.ipynb` | **Notebook** — lihat di bawah |
| 3 | `03_ml/33_m2_revenue_forecast.sql` | Editor Workspace |
| 4 | `03_ml/34_m6_anomaly_detection.sql` | Editor Workspace |
| 5 | `03_ml/35_m3_agent_scoring.sql` | Editor Workspace |
| 6 | `03_ml/36_m5_customer_clv.sql` | Editor Workspace |
| 7 | `03_ml/37_m7_cross_sell.sql` | Editor Workspace |
| 8 | `03_ml/38_m4_nba_recommendations.sql` | Editor Workspace |

### Menjalankan notebook M1

1. Di daftar file Workspace, klik `03_ml/32_m1_train_xgboost.ipynb`
2. Di kanan atas, buka menu **Packages** dan tambahkan: `xgboost`, `scikit-learn`, `pandas`,
   `numpy`
3. Pilih warehouse `GEN2_SMALL`
4. Jalankan sel dari atas ke bawah (**Cmd/Ctrl+Enter** per sel, atau **Run all**)

Notebook memakai `get_active_session()`, jadi sudah terautentikasi sebagai Anda. Tidak ada yang
perlu dikonfigurasi.

> Versi `.py` dari langkah ini tetap ada di repo untuk pengguna CLI. Notebook dan script berbagi
> kode yang sama — notebook mengambil fungsi helper-nya langsung dari script — jadi hasilnya
> identik.

**Runtime**: sekitar 12 menit, 3 menit di antaranya untuk XGBoost.

### Urutan dependensi itu penting

```
20 → 21 → 22 → 23 → 24 → 25 → 26          (fondasi data)
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   31 → 32 (M1)      33 (M2)          34 (M6)      ← saling independen
        │
        ▼
   36 (M5 CLV — butuh M1)
        │
        ▼
   37 (M7 cross-sell — butuh M5)
        │
        ▼
   38 (M4 NBA — butuh M1 + M3 + M5 + M7)
```

**Kalau Anda meng-generate ulang data, seluruh rantai ini wajib dijalankan ulang.** Kami pernah
meng-generate ulang `FACT_POLICY` setelah melatih M1, dan 5.547 dari 5.986 skor lapse diam-diam
menunjuk ke agen yang salah. Tidak ada error apa pun untuk kasus ini — angkanya hanya salah.

### Apa yang dilakukan setiap model

| Model | Teknik | Tabel output | Baris |
|-------|--------|--------------|-------|
| **M1 Lapse** | XGBoost pada panel point-in-time | `LAPSE_RISK_SCORES` | 6.002 |
| **M2 Forecast pendapatan** | `SNOWFLAKE.ML.FORECAST` | `REVENUE_FORECAST_RESULTS` | 138 |
| **M3 Skoring agen** | Aturan berbasis perilaku | `AGENT_PERFORMANCE_SCORES` | 1.071 |
| **M4 Next best action** | Rule engine di atas M1+M3+M5+M7 | `AI_RECOMMENDATIONS` | 5.148 |
| **M5 Customer CLV** | Proyeksi aktuaria | `CUSTOMER_CLV_SCORES` | 4.362 |
| **M6 Deteksi anomali** | `SNOWFLAKE.ML.ANOMALY_DETECTION` | `PRODUCTION_ANOMALIES` | 138 |
| **M7 Cross-sell** | Association rules (lift) | `CROSS_SELL_RECOMMENDATIONS` | 7.607 |

### Checkpoint 2 — metrik M1 yang jujur

```sql
SELECT * FROM INSURANCE_DEMO.CORE.ML_MODEL_METRICS;
```

Anda seharusnya melihat **TEST ROC-AUC ≈ 0,827**, PR-AUC ≈ 0,312, recall@top-10% ≈ 0,592,
Brier 0,0282 dibanding baseline 0,0334. Hasil lengkap, terukur langsung di Snowflake:

| Split | ROC-AUC | PR-AUC | recall@top-10% | Brier |
|---|---|---|---|---|
| TRAIN | 0,9311 | 0,5522 | 0,7803 | 0,0177 |
| VALID | 0,8456 | 0,3951 | 0,5938 | 0,0265 |
| **TEST** | **0,8274** | **0,3115** | **0,5915** | **0,0282** |

TEST berisi 41.217 baris dengan 1.427 positif, base rate 3,46%.

Angka desimal ketiga wajar bergeser sedikit. Channel Anaconda Snowflake memakai
**xgboost 3.3.0**, sementara varian `.py` dari langkah ini kalau dijalankan di laptop
biasanya me-resolve XGBoost versi lebih lama; selisih itu sendiri menggeser TEST ROC-AUC
antara 0,827 dan 0,828. Selama masih di rentang itu, run Anda sehat.

**Kalau Anda melihat 0,97, ada yang salah.** Percobaan pertama kami menghasilkan 0,9725 — bukan
karena kebocoran temporal, tapi karena generator membuat pola keterlambatan bayar sebelum lapse
menjadi fungsi yang nyaris sempurna dari label (60,5% polis yang akan lapse terlambat >20 hari,
versus 0,1% polis lainnya). Kami memperbaiki **generator**-nya, bukan modelnya: sekarang hanya
55% lapse yang menunjukkan tanda-tanda memburuk, 14% polis sehat justru pernah terlambat lalu
pulih, dan ramp-nya diperlebar jadi delapan bulan. Model demo yang mencetak 0,97 untuk masalah
bisnis seperti ini bukan mengesankan — itu rusak.

Ablasi, untuk membuktikan setiap fitur berkontribusi: tenure saja 0,711 → tambah billing 0,811 →
fitur lengkap 0,827. Notebook mencetak tiga baris ini tapi tidak menyimpannya, jadi bacalah
dari output sel-nya, bukan dari `ML_MODEL_METRICS`.

### Keterbatasan M6 yang terdokumentasi

Premi per cabang per bulan punya koefisien variasi sekitar 0,70 — hanya 3 sampai 10 polis per
cabang per bulan — sehingga deteksi anomali bulanan kurang bertenaga. Kami beralih ke deret
**rolling 3 bulan** (CV 0,48). Hasilnya: 21 flag dari 138, menangkap 8 dari 14 bulan-kejadian
yang ditanam dan **semua 6 cabang** yang punya kejadian tertanam, dengan 13 false positive.
Sebutkan ini terus terang saat demo. Detektor yang menemukan semua cabang tapi agak berlebihan
menandai itu berguna; detektor yang Anda klaim sempurna itu liabilitas.

---

## Langkah 3 — Dokumen Produk dan Cortex Search

Langkah ini menunjukkan data tidak terstruktur bekerja berdampingan dengan star schema: AI
menulis brosur, dirender jadi PDF ber-branding, lalu Snowflake mem-parsing, meng-chunk, dan
mengindeksnya.

| Urutan | File | Cara menjalankan |
|--------|------|------------------|
| 1 | `04_search/41_generate_brochures.sql` | Editor Workspace, statement demi statement |
| 2 | `04_search/42_render_pdfs.ipynb` | **Notebook** — tambahkan paket `reportlab` dulu |
| 3 | `04_search/43_parse_and_search.sql` | Editor Workspace |

Notebook membangun setiap PDF di memori lalu mengalirkannya langsung ke `@STAGE_DOC` dengan
`session.file.put_stream()` — tidak ada file yang ditulis ke disk, jadi tidak ada langkah unggah
dan tidak ada `PUT` yang bisa salah.

**Runtime**: sekitar 9 menit. Langkah `41` yang paling lama — 24 panggilan `AI_COMPLETE`
berurutan.

Apa yang terjadi:

1. `41` — `AI_COMPLETE` dengan `claude-4-sonnet` menulis 24 brosur fiktif (3 per klasifikasi
   produk, satu per tier), rata-rata 7.434 karakter
2. `42` — renderer Markdown-ke-PDF kecil menghasilkan PDF 3 halaman ber-branding
   (teal `#0E5C63`, gold `#D4A03C`) dan mengunggahnya ke `@STAGE_DOC`
3. `43` — `AI_PARSE_DOCUMENT` mode LAYOUT mengekstrak teksnya,
   `SPLIT_TEXT_RECURSIVE_CHARACTER` meng-chunk (markdown, 1500/200), dan
   `CREATE CORTEX SEARCH SERVICE` mengindeks 164 chunk dengan `arctic-embed-l-v2.0`

Setiap chunk diberi awalan `Product: <nama> (<kode>, <kelas>)` supaya potongan yang ditemukan
tetap menjelaskan dirinya sendiri meski lepas dari konteks.

### Checkpoint 3

```sql
SELECT COUNT(*) AS chunks FROM INSURANCE_DEMO.CORE.DOCS_CHUNKS;             -- 164
SHOW CORTEX SEARCH SERVICES LIKE 'MERIDIAN_PRODUCT_SEARCH';                 -- ACTIVE

SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'INSURANCE_DEMO.CORE.MERIDIAN_PRODUCT_SEARCH',
  '{"query": "critical illness waiting period", "limit": 3}');
```

---

## Langkah 4 — Semantic View

Semantic view adalah yang memungkinkan Cortex Analyst mengubah pertanyaan bahasa manusia menjadi
SQL yang benar. Ia mendeklarasikan tabel, cara join-nya, kolom mana yang fakta dan dimensi,
ekspresi mana yang metrik, dan sekumpulan contoh query terverifikasi.

```
05_semantic_view/51_semantic_view.sql
```

File ini berisi satu statement `CREATE OR REPLACE SEMANTIC VIEW` yang sangat panjang. Letakkan
kursor di mana saja di dalamnya dan tekan **Cmd/Ctrl+Enter** sekali.

Hasil: `MERIDIAN_SALES_INTELLIGENCE` — 22 tabel, 21 relationship, 44 fakta, 94 dimensi,
40 metrik, 12 verified query.

### Checkpoint 4 — ajukan pertanyaan sungguhan

```sql
-- Pencapaian per cabang. Harus sama dengan V_BRANCH_ACHIEVEMENT.
SELECT * FROM SEMANTIC_VIEW(
  INSURANCE_DEMO.CORE.MERIDIAN_SALES_INTELLIGENCE
  DIMENSIONS branches.branch_name
  METRICS    branch_achievement.achievement_rate_pct
) ORDER BY 2 LIMIT 5;
```

Cabang dengan pencapaian terendah di Jawa Timur harus keluar sebagai **Jember, sekitar 44%**.
Kami memverifikasi semantic view terhadap view dasarnya: selisih maksimum **0,0048 poin
persentase**.

### Tiga aturan semantic view yang tidak boleh dilanggar

Ini menghabiskan waktu kami berjam-jam. Kalau Anda mengedit `51_semantic_view.sql`, ingat ini.

1. **Urutan klausa itu wajib**: `TABLES`, `RELATIONSHIPS`, `FACTS`, `DIMENSIONS`, `METRICS`,
   `COMMENT`, `MAX_STALENESS`, `AI_SQL_GENERATION`, `AI_QUESTION_CATEGORIZATION`,
   `AI_VERIFIED_QUERIES`. Selain itu, `AI_SQL_GENERATION 'text'` **tanpa tanda sama dengan**,
   dan verified query memakai keyword bukan assignment:
   `nama AS ( QUESTION '...' SQL '...' )`.
2. **Sebuah metrik tidak boleh bernama sama dengan kolom fisik** yang direferensikan ekspresi
   lain di tabel yang sama, atau muncul error *"Cyclic reference of expressions"*.
   Referensi ke diri sendiri (`city AS CITY`) tidak masalah.
3. **Paling penting: nama ekspresi semantic harus sama dengan nama kolom fisiknya.** Kalau tidak,
   penulisan ulang verified query akan diam-diam menghasilkan SQL yang rusak — Analyst membangun
   CTE internal yang hanya memuat kolom yang nama semantic dan fisiknya cocok, dan kolom lain di
   query itu jadi `invalid identifier`. Synonym dan alias juga berbagi satu namespace global dan
   semuanya harus unik.

---

## Langkah 5 — Cortex Agent

```
06_agent/61_agent_procedures.sql
06_agent/62_pptx_procedure.sql
06_agent/63_agent.sql
```

Membuat 10 stored procedure, satu pembuat PowerPoint, dan
`MERIDIAN_COMMAND_CENTER_AGENT` dengan 15 tool:

| Jenis tool | Tool |
|------------|------|
| Cortex Analyst | `query_sales_intelligence` |
| Cortex Search | `search_product_docs` |
| Procedure | `predict_lapse_risk`, `get_revenue_forecast`, `score_agent_performance`, `get_customer_clv`, `detect_production_anomalies`, `get_cross_sell_suggestions`, `get_branch_scorecard`, `save_agent_recommendation`, `save_branch_recommendation`, `assign_retention_calls`, `generate_pptx_report` |
| Bawaan | `create_chart`, `web_search` |

### Kontrak procedure — baca ini sebelum membuat tool sendiri

- Procedure harus `RETURNS VARCHAR` dan mengeluarkan **satu sel JSON**:
  `COALESCE(TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT(*))), '[]')`.
  `RETURNS TABLE` **tidak bisa dibaca** oleh generic agent tool.
- Di dalam body `LANGUAGE SQL`, rujuk parameter dengan awalan titik dua: `:P_BRANCH_ID`. Tanpa
  itu, Snowflake menganggapnya nama kolom dan memunculkan *invalid identifier*.
- `LIMIT` tidak bisa menerima bind variable. Pakai
  `QUALIFY ROW_NUMBER() OVER (...) <= :P_LIMIT`.
- Nama properti di `input_schema` harus sama dengan nama parameter procedure, huruf kecil. Agent
  mengirim `''` untuk "tidak disediakan", jadi perlakukan string kosong sebagai NULL.
- `tool_resources` adalah **map top-level tersendiri** di spec YAML, dikunci nama tool — bukan
  bersarang di dalam `tools`.

### Checkpoint 5 — jalankan lima tes

Output referensi ada di `06_agent/tests/`. Tanyakan ke agent di Snowsight
(**AI & ML → Agents**) atau lewat REST API:

| Tes | Pertanyaan | Bukti berhasil |
|-----|-----------|----------------|
| t1 | *Which branches are below target in 2025?* | 17 dari 23 di bawah rencana; 5 kritis, terburuk Jember 43,99% |
| t2 | *Apa saja manfaat dan pengecualian ...* (bahasa Indonesia) | Menjawab dari brosur dan mengutip **nama produk**, bukan nama file |
| t3 | *Why is Malang declining and what should we do?* | Temuan / akar masalah / rekomendasi, memakai 4 tool sekaligus |
| t4 | *How does our persistency compare to the market?* | Memakai web search, mengatribusikan angka eksternal secara terpisah |
| t5 | *Save a recovery recommendation for Jember and generate a deck* | Menulis baris dengan `CREATED_BY='CORTEX_AGENT'`, mengembalikan link PPTX yang berfungsi |

Pada t3 kami memverifikasi kesembilan angka yang dikutip terhadap data sebenarnya — pencapaian
81,98%, gap Rp 214,57 juta, 50 agen dengan 31 lemah dan 1 top performer, 25 polis berisiko
tinggi, Rp 159 juta terancam, dan anomali November 2025 sebesar −81,33%. Nol halusinasi. Ulangi
pemeriksaan ini kalau Anda mengubah tool-nya; ini bukti terkuat bahwa desainnya bekerja.

---

## Langkah 6 — Dashboard Streamlit

```
07_streamlit/71_deploy_streamlit.sql
```

Membuat `MERIDIAN_COMMAND_CENTER_DASHBOARD`, 7 halaman, chart Plotly, branding Meridian. Buka di
Snowsight lewat **Projects → Streamlit**.

File ini **tidak memakai `PUT`**. Ia memakai `COPY FILES` untuk memindahkan `app.py`,
`environment.yml`, dan `.streamlit/config.toml` dari Workspace Anda ke `@STAGE_STREAMLIT_APP`,
lalu membuat objek Streamlit-nya. Jalankan statement demi statement dan baca query
verifikasinya — harusnya muncul tepat 3 file.

> **Nama Workspace berpengaruh di sini.** Path sumber `COPY FILES` memuat
> `"meridian-life-agentic-ai-demo"`. Kalau Anda mengganti nama Workspace, jalankan
> `SHOW TERSE WORKSPACES IN SCHEMA USER$.PUBLIC;` (statement pertama di file itu), lalu masukkan
> nama persis Anda ke kedua statement `COPY FILES`. Namanya *case-sensitive* dan tanda kutip
> gandanya wajib.

`environment.yml` sengaja tidak menyematkan versi Python — biarkan Snowflake yang memilih, atau
deployment bisa gagal karena kombinasi yang tidak didukung.

---

## Langkah 7 — Closed Loop

```
08_closed_loop/81_closed_loop.sql
```

Inilah yang mengubah demo dari "AI menyarankan sesuatu" menjadi "AI menyarankan sesuatu dan kita
tahu apakah itu berhasil". Membuat `RECOMMENDATION_FEEDBACK` (1.785 baris awal) dan
`RECOMMENDATION_OUTCOME` (1.113), plus dua view: `V_RECOMMENDATION_LOOP` dan
`V_MODEL_EFFECTIVENESS` (win rate, realisasi).

Status rekomendasi setelah seeding: OPEN 3.834 · DONE 732 · IN_PROGRESS 381 · DISMISSED 202.

---

## Cara Memakai Demo

### Pertanyaan yang dijawab agent dengan baik

```
Which branches are below target in 2025?
Why is Jember declining and what should we do about it?
What are the benefits and exclusions of Meridian Sehat Gold?
Show me the 20 policies most likely to lapse and who should call them
Which high value customers only hold one product?
What is our 2026 revenue outlook by branch?
```

### Alur demo yang terbukti jalan

1. **Dashboard** — buka Command Center. Rencana versus aktual, 17 cabang tertinggal.
2. **Tanya kenapa** — pindah ke agent: *"Why is Jember declining?"* Satu panggilan tool
   (`get_branch_scorecard`) mengembalikan pencapaian, anomali terbaru, komposisi agen, dan
   eksposur lapse sekaligus.
3. **Minta tindakan konkret** — *"Show me the 20 policies most likely to lapse in Jember and
   assign retention calls."* Agent menulis baris kembali ke database.
4. **Tutup loop-nya** — tunjukkan `V_MODEL_EFFECTIVENESS`: dari rekomendasi sebelumnya, mana yang
   ditindaklanjuti dan mana yang menghasilkan hasil.

Poin yang harus mendarat: **loop-nya itu produknya.** Forecast yang tidak ditindaklanjuti hanya
laporan.

---

## Arsitektur dan Keputusan Desain

```
SUMBER               FONDASI               AI / ML              AGENT              KONSUMSI
14 tabel        →   Semantic View      →  Cortex Search     →  Cortex Agent    →  Streamlit
PDF di stage        Helper view           Output M1–M7         (15 tool)          Dashboard
                    Governance            CLV/Lapse/NBA        + web search       (7 halaman)
                                                                    │
                                                                    └→ AI_RECOMMENDATIONS ─┐
                                                                                           │
                                    RECOMMENDATION_FEEDBACK / OUTCOME ←────────────────────┘
```

Enam keputusan yang perlu Anda pahami sebelum mengubah apa pun:

1. **Pencapaian anti-fan-out.** `V_BRANCH_ACHIEVEMENT` meng-agregasi target dan aktual
   **secara terpisah** lalu baru menggabungkannya. **Jangan pernah men-join
   `FACT_BRANCH_TARGET` langsung ke `FACT_AGENT_PRODUCTION`** — satu baris target dikalikan
   banyak baris produksi akan menggelembungkan target, dan semua persentase pencapaian diam-diam
   jadi salah.
2. **Tidak ada target per agen.** Target hanya ada di level cabang, sebagaimana praktik sebagian
   besar perusahaan asuransi. Karena itu penilaian agen (M3) berbasis perilaku, bukan target.
3. **M1 anti-kebocoran secara desain.** Panel point-in-time dengan fitur jendela ke belakang
   saja, dibagi secara temporal: train 2023-04→2024-08, validasi 2024-09→2024-12, test
   2025-01→2025-10.
4. **Procedure mengembalikan VARCHAR JSON** — lihat kontraknya di Langkah 5.
5. **Diagnosis sekali jalan.** `GET_BRANCH_SCORECARD` sengaja membundel pencapaian, anomali,
   komposisi agen, eksposur lapse, dan pipeline terbuka dalam satu panggilan, supaya agent tidak
   memecah satu pertanyaan jelas menjadi empat panggilan tool. Begitu juga
   `ASSIGN_RETENTION_CALLS` yang batch, supaya agent tidak mengulang per agen.
6. **Jangan pakai `scale_pos_weight` pada M1.** M5 mengonsumsi probabilitas M1, jadi
   probabilitasnya harus tetap terkalibrasi. Pakai `base_score=y_train.mean()` dan `logloss`.

---

## Troubleshooting

| Gejala | Penyebab dan solusi |
|--------|---------------------|
| `unknown model "claude-4-sonnet"` | Cross-region inference belum aktif. Lihat [3.2](#32-cross-region-inference--wajib) |
| Pembuatan Workspace gagal di bagian integration | Nama integration harus **HURUF BESAR semua**. Huruf kecil ditolak |
| `COPY FILES` tidak menemukan apa pun | Nama Workspace Anda berbeda dari yang ada di SQL. Jalankan `SHOW TERSE WORKSPACES IN SCHEMA USER$.PUBLIC;` dan pakai nama persis Anda, dalam tanda kutip ganda |
| Notebook tidak bisa `import xgboost` atau `reportlab` | Tambahkan di menu **Packages** di kanan atas notebook, lalu restart session-nya |
| `get_active_session()` gagal | Anda menjalankan file `.py`, bukan `.ipynb`. Notebook punya session aktif; script tidak |
| Sebuah statement seperti menggantung | Beberapa statement generate data butuh 30–60 detik. Pastikan warehouse tidak suspended, dan biarkan selesai |
| `Unsupported subquery type` | `EXISTS` berkorelasi dengan predikat rentang. Tulis ulang sebagai semi-join |
| Hanya sebagian cabang mendapat agen | Anda memakai `RANDOM(seed)` lagi. Fungsi itu dievaluasi ulang per baris pada join perantara, sehingga pemilihan berbobot kolaps. Pakai UDF `RND()` berbasis hash |
| AUC test M1 ≈ 0,97 | Artefak generator, bukan model bagus. Lihat [Checkpoint 2](#checkpoint-2--metrik-m1-yang-jujur) |
| Probabilitas M1 menumpuk di sekitar 0,5, Brier lebih buruk dari baseline | Terlalu diregularisasi dan salah titik pusat. Pakai `base_score=y_train.mean()`, `eval_metric='logloss'`, regularisasi moderat |
| Skor lapse menunjuk agen yang salah | Output ML basi setelah data di-generate ulang. Jalankan ulang 22→23→24→25→26, lalu 31→32, lalu 36→37→38 |
| Verified query mengembalikan `invalid identifier` | Nama ekspresi semantic berbeda dari nama kolom fisiknya. Lihat [Langkah 4 aturan 3](#tiga-aturan-semantic-view-yang-tidak-boleh-dilanggar) |
| `Cyclic reference of expressions` | Sebuah metrik bernama sama dengan kolom fisik yang direferensikan di tempat lain pada tabel yang sama |
| PDF brosur ter-render sebagai satu blok tanpa jeda | `AI_COMPLETE` mengembalikan VARIANT. Cast dulu: `AI_COMPLETE(...)::STRING`. Tanpa cast, isinya string JSON dengan `\n` literal dan tanda kutip pembungkus |
| Tool agent tidak mengembalikan apa pun yang berguna | Procedure-nya memakai `RETURNS TABLE`. Ubah ke `RETURNS VARCHAR` dengan satu sel JSON |
| `invalid identifier 'P_BRANCH_ID'` | Kurang awalan titik dua di dalam body `LANGUAGE SQL`. Pakai `:P_BRANCH_ID` |
| PUT gagal dengan "unexpected" | Path mengandung spasi tanpa tanda kutip. Kutip seluruh argumen `file://`. Hanya relevan di jalur CLI |
| Deploy Streamlit gagal karena paket | Hapus sematan `python=` dari `environment.yml` |
| Agent tidak muncul di Snowsight | Berikan `USAGE ON AGENT`, dan pastikan user punya default warehouse |
| M6 menandai terlalu banyak bulan-cabang | Sudah diketahui dan terdokumentasi. Pakai deret rolling 3 bulan; `IS_CONFIRMED_ANOMALY` menekan false positive tapi mengurangi recall |

---

## Biaya dan Pembersihan

Tidak ada komponen di demo ini yang menagih terus-menerus — tidak ada compute pool dan tidak ada
container service. Warehouse-nya auto-suspend setelah 60 detik.

Perkiraan biaya build: **beberapa kredit**, didominasi 24 panggilan `AI_COMPLETE` untuk brosur
dan langkah `AI_PARSE_DOCUMENT`. Biaya idle setelah build praktis nol.

Untuk menghapus semuanya:

```sql
USE ROLE ACCOUNTADMIN;
DROP DATABASE IF EXISTS INSURANCE_DEMO;
DROP WAREHOUSE IF EXISTS GEN2_SMALL;   -- hanya kalau Anda membuatnya khusus untuk demo ini
```

### Membagikan ke pengguna lain

```sql
CREATE ROLE IF NOT EXISTS DEMO_COWORK;
GRANT USAGE ON DATABASE INSURANCE_DEMO TO ROLE DEMO_COWORK;
GRANT USAGE ON SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON ALL TABLES IN SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON ALL VIEWS IN SCHEMA INSURANCE_DEMO.CORE TO ROLE DEMO_COWORK;
GRANT SELECT ON SEMANTIC VIEW INSURANCE_DEMO.CORE.MERIDIAN_SALES_INTELLIGENCE TO ROLE DEMO_COWORK;
GRANT READ ON STAGE INSURANCE_DEMO.CORE.STAGE_DOC   TO ROLE DEMO_COWORK;
GRANT READ ON STAGE INSURANCE_DEMO.CORE.STAGE_EXPORT TO ROLE DEMO_COWORK;
GRANT USAGE ON WAREHOUSE GEN2_SMALL TO ROLE DEMO_COWORK;
GRANT USAGE ON AGENT INSURANCE_DEMO.CORE.MERIDIAN_COMMAND_CENTER_AGENT TO ROLE DEMO_COWORK;
```

`SELECT ON SEMANTIC VIEW` dan `READ ON STAGE` adalah dua grant yang paling sering terlupakan.

Cortex Agent memakai **default warehouse dan role milik user yang memanggil**, bukan milik
session. Jadi setiap pengguna demo wajib punya default:

```sql
ALTER USER <username> SET DEFAULT_WAREHOUSE = 'GEN2_SMALL', DEFAULT_ROLE = 'DEMO_COWORK';
```

---

## Struktur Repository

```
meridian-life-demo/
├── README.md                      ← versi bahasa Inggris
├── README-IND.md                  ← file ini
├── 01_setup/
│   └── 01_setup.sql               warehouse, database, schema, 3 stage
├── 02_generate_data/
│   ├── 20_gen_helpers.sql         UDF RND/RNDI/RNDN deterministik
│   ├── 21_dimensions.sql          cabang, agen, nasabah, produk
│   ├── 22_fact_policy.sql         7.400 polis dengan pola tertanam
│   ├── 23_fact_policy_children.sql pembayaran, rider, klaim
│   ├── 24_fact_agent.sql          produksi, aktivitas, perilaku app, training
│   ├── 25_fact_target_crm.sql     target cabang, tiket CRM
│   ├── 26_helper_views.sql        6 view termasuk V_BRANCH_ACHIEVEMENT
│   └── 27_verify_stop1.sql        checkpoint 1
├── 03_ml/                         M1–M7 (31–38)
│   ├── 31_m1_lapse_panel.sql
│   ├── 32_m1_train_xgboost.ipynb  ← notebook (disarankan)
│   ├── 32_m1_train_xgboost.py     ← kode sama, untuk pengguna CLI
│   └── 33–38 …
├── 04_search/                     brosur → PDF → Cortex Search (41–43)
│   ├── 41_generate_brochures.sql
│   ├── 42_render_pdfs.ipynb       ← notebook (disarankan)
│   ├── 42_render_pdfs.py          ← kode sama, untuk pengguna CLI
│   └── 43_parse_and_search.sql
├── 05_semantic_view/
│   ├── 51_semantic_view.sql
│   └── dedupe_synonyms.py         jalankan setelah mengedit synonym
├── 06_agent/
│   ├── 61_agent_procedures.sql    10 procedure
│   ├── 62_pptx_procedure.sql      PPTX + presigned URL
│   ├── 63_agent.sql               spec agent (YAML)
│   └── tests/                     output referensi t1–t5
├── 07_streamlit/
│   ├── streamlit_app/             app.py, environment.yml, .streamlit/
│   └── 71_deploy_streamlit.sql
├── 08_closed_loop/
│   └── 81_closed_loop.sql
└── docs/
    ├── demo-guideline.md          skrip demo per scene
    └── data-dictionary.md         seluruh tabel dan kolom
```

---

## Lampiran — Memakai CLI

Jalur Workspace di atas tidak butuh instalasi apa pun, dan itu yang kami sarankan. Kalau Anda
lebih suka bekerja dari terminal, semuanya tetap berfungsi.

```bash
pip install snowflake-cli
snow connection add          # membuat ~/.snowflake/connections.toml, di luar repo ini
snow connection test -c meridian
export SNOWFLAKE_CONNECTION_NAME=meridian
```

Lalu, **dari root repository**:

```bash
snow sql -c meridian -f 01_setup/01_setup.sql
snow sql -c meridian -f 02_generate_data/20_gen_helpers.sql
# ... dan seterusnya, dalam urutan yang sama dengan langkah-langkah di atas
```

Untuk dua langkah Python, pakai file `.py` alih-alih notebook. Keduanya butuh environment lokal:

```bash
conda create -n meridian python=3.11 -y && conda activate meridian
pip install "snowflake-connector-python[pandas]" \
            xgboost scikit-learn pandas numpy reportlab

python 03_ml/32_m1_train_xgboost.py
python 04_search/42_render_pdfs.py
```

Untuk deploy Streamlit, ganti statement `COPY FILES` dengan tiga perintah `PUT` — bentuk
persisnya ada di bagian akhir `07_streamlit/71_deploy_streamlit.sql`.

> **Jangan pernah** commit `connections.toml`, private key, atau personal access token.
> `.gitignore` yang disertakan sudah memblokir yang umum, tapi kebiasaan paling aman adalah
> menyimpan kredensial hanya di config CLI.

---

## Catatan dan Keterbatasan

- **Meridian Life fiktif.** Setiap cabang, agen, nasabah, produk, dan brosur adalah sintetis.
  Jangan pernah menyajikan angka di sini sebagai benchmark industri.
- **Tidak ada PII nyata.** Nama diambil dari kumpulan nama hasil generate.
- **Ini demo, bukan sistem produksi.** Tidak ada CI, tidak ada migrasi skema, tidak ada
  monitoring.
- **M6 kurang bertenaga pada granularitas bulanan** dan sudah didokumentasikan demikian. Jangan
  mengklaim presisi yang tidak dimilikinya.
- **Tool web search pada agent** mengakses internet publik. Kalau akun Anda melarangnya, hapus
  tool itu dari spec; 14 tool lainnya tetap berfungsi.

---

*Dibangun di Snowflake dengan Cortex Analyst, Cortex Search, Cortex Agents, Snowflake ML, dan
Streamlit in Snowflake.*

---

## Lisensi

Apache License 2.0 — lihat [LICENSE](./LICENSE).

Ini proyek demonstrasi pribadi. Bukan produk resmi Snowflake dan tidak didukung oleh
Snowflake Inc. Semua nama perusahaan, cabang, agen, nasabah, produk, dan brosur adalah fiktif.
