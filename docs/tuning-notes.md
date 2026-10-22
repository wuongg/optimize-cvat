# Low-RAM notes

## Cách chạy

- Lần đầu: `docker compose up -d --build` (build image lowram một lần)
- Các lần sau: `docker compose up -d` (dùng image đã build)
- Nâng cấp upstream: `docker compose up -d --build` lại

Số dưới đây là peak WorkingSet của mọi process Edge khi cuộn 60 giây, hoặc `settings.CVAT_CACHE_ITEM_MAX_SIZE` trên process đang chạy. Không dùng WorkingSet sau GC để kết luận peak.

## 1. Đã chứng minh có tác dụng

| Thay đổi | Bằng chứng | Đánh đổi |
| --- | --- | --- |
| `CVAT_ALLOW_STATIC_CACHE=yes` | `MEDIA_CACHE_ALLOW_STATIC_CACHE` đọc env này. Task mới được phép ghi chunk tĩnh ra đĩa; lần đọc sau không decode lại trong RAM server. | Đĩa tăng theo dữ liệu task. |
| `CVAT_CACHE_ITEM_MAX_SIZE=67108864` | `from django.conf import settings; print(settings.CVAT_CACHE_ITEM_MAX_SIZE)` in 67108864 trên `cvat_server` và `cvat_worker_utils`. Image mặc định là 500 MiB. | Chunk lớn hơn 64 MiB không vào cache; lần sau phải decode lại. |

Mọi tham số đọc từ env chỉ có tác dụng nếu file chứa nó nằm trong `docker/Dockerfile.lowram`. Hiện image COPY 5 file; `task.py` không nằm trong số đó. Trước khi kết luận một env var "không giúp", phải chứng minh file đọc nó có trong image — bằng `docker exec cvat_server grep -n <TÊN_BIẾN> /opt/cvat/...`.

`default_settings.py` đọc env, mặc định vẫn 500 MiB nếu không set. `base.py` re-export tên này để `django.conf.settings` thấy trước `AppConfig.ready()`. `docker compose up -d` dùng image `cvat/server:lowram`, trong đó hai file này đã được bake sẵn. Default 64MB nằm trong `docker-compose.yml`.

## 2. Dead config

| Tên | Vì sao chết |
| --- | --- |
| `image_quality` | Không có env. UI mặc định 70 tại `advanced-configuration-form.tsx:88` và luôn gửi khi tạo task (`tasks-actions.ts:249`). |
| `CVAT_CONCURRENT_CHUNK_PROCESSING` | `base.py` đã mặc định 1. Ghi thêm 1 trong overlay không đổi hành vi. |

## 3. Đã bác bỏ

| Giả thuyết | Số đo | Kết luận |
| --- | --- | --- |
| Cap cache client = 2 giảm RAM | Sau GC: cap 10 là 1786.3 MB, cap 2 là 1498.0 MB, giảm 288.3 MB. Peak khi cuộn: P10 2027.0, P2 2016.8, chênh 10.2 MB, nhiễu lớn nhất 26.6 MB. | Bác. Source giữ cap 10. |
| Chunk 12 tiết kiệm ~1 GB so với chunk 36, cùng 200 frame | Peak trung vị chunk 36 là 2036.8 MB, chunk 12 là 2016.2 MB, chênh 20.6 MB. | Bác. Mô hình ~1 GB sai. |
| 720p đưa peak 200 frame xuống 1.3–1.5 GB | Peak trung vị 720p là 2437.7 MB, cao hơn 2036.8 MB là 400.9 MB. | Bác. 720p nặng hơn. |
| Sàn ~1 GB là bitmap 1080p | 540p, 200 frame, peak 1955.5 MB. Bitmap 1080p trong cache là 2.07 MB/frame, không phải 8.3 MB. | Bác. Phần khoảng 1.5 GB không theo pixel nguồn. |
| `CVAT_DEFAULT_CHUNK_SIZE=12` hạ peak server của video 1080p 50 frame | Hai vòng, container tạo mới, `scripts/bench_cvat.ps1`. Vòng 1 worker 546.9 MiB (chunk 36) và 546.7 MiB (chunk 12), stack 1028.2 và 1032.9. Vòng 2 worker 550.5 và 553.4, stack 1036.7 và 1046.0. Chênh lớn nhất 0.9% stack, chunk 12 không thấp hơn. | Bác. Lúc đo, `task.py` được COPY tạm vào image; DB task 11 và 13 là chunk 36, task 12 và 14 là chunk 12. Chênh stack 0.5% và 0.9%. Code đọc env đã gỡ. Commit không giữ COPY đó. |

## 4. Phát hiện downscale ngầm

Chunk video nén không giữ độ phân giải nguồn khi chiều cao ≥ 1080. `Mpeg4CompressedChunkWriter.save_as_chunk`:

```python
downscale_factor = 1
while input_h / downscale_factor >= 1080:
    downscale_factor *= 2

output_h = input_h // downscale_factor
output_w = input_w // downscale_factor
```

Client vẫn `setRenderSize` theo meta gốc và vẽ bitmap nhỏ lên kích thước đó. Pixel trong cache là kích thước chunk.

| Nguồn | factor | Chunk lưu | MB/bitmap | Peak 200 frame |
| --- | --- | --- | --- | --- |
| 960×540 | 1 | 960×540 | 2.07 | 1955.5 MB |
| 1280×720 | 1 | 1280×720 | 3.69 | 2437.7 MB |
| 1920×1080 | 2 | 960×540 | 2.07 | 2000.0 MB (mốc trước 2036.8) |
| 3840×2160 | 4 | 960×540 | 2.07 theo công thức | chưa đo |

`GET /api/tasks/<id>/data/meta` xác nhận meta 1920×1080, 1280×720, 960×540 trước khi đo. ImageBitmap đọc sau khi cuộn khớp cột “Chunk lưu”.

## 5. Ngân sách vận hành

Cùng video 1080p, chunk 36. Peak Edge:

| Frame/job | Peak |
| --- | --- |
| 50 | 1234 MB |
| 100 | 1557 MB |
| 200 | 2036 MB |

Giữ 1080p và chia job. 50 frame nằm dưới 1.5 GB. 100 frame và 200 frame nằm trên 1.5 GB. Hạ độ phân giải hoặc hạ chunk không đưa job 200 frame xuống dưới 1.5 GB. 50 frame vẫn trên 900 MB và 1200 MB, nên hai mức đó chưa có cấu hình đo được.

## 6. Chunk size cho point cloud

`task.py` tính `chunk_size` từ `area = WIDTH × HEIGHT` của header PCD. Với cloud
không tổ chức, `HEIGHT = 1` nên `area` là **số điểm**, và công thức giữ tích
`chunk_size × N ≈ 74.6M` điểm. Nghĩa là `chunk_size = 72` với mọi cloud nhỏ hơn
~1M điểm, và mỗi request chunk mang theo 72 cloud dù client chỉ vẽ một cái.

Số đo: 80 cloud, mỗi file 800151 byte (0.763 MiB). Trước: task 17, `chunk_size` 72, `segment_16-0.zip` 57617806 byte (54.95 MiB), 2 chunk, `du` 123M. Sau: task 18, `chunk_size` 10, `segment_17-0.zip` 8002492 byte (7.63 MiB), 8 chunk.

Đã sửa: nhánh riêng cho `DIM_3D`, budget theo **byte file**
(`CVAT_3D_CHUNK_BUDGET`, mặc định 8 MiB). `max(1, ...)` chỉ áp cho 3D.

Nhánh cloud storage không có kích thước byte trong manifest, nên ước lượng 32 B/điểm. `chunk_size` trên cloud có thể nhỏ hơn nhánh local. Chưa đo — đây là ước lượng.

### Chunk original không được ghi cho point cloud

Với point cloud, cả `ZipChunkWriter` và `ZipCompressedChunkWriter` ghi `.pcd`
nguyên văn bằng `ZIP_STORED` (`_write_pcd_file` không nén, `writestr` không
truyền `compress_type`), nên hai chunk byte-đối-byte — đo md5 giống nhau,
`compress_type = 0`. `ZipCompressedChunkWriter` vẫn override `save_as_chunk`,
nên so hai method bằng `is` ra False. Điều kiện bỏ lượt zip là `DIM_3D` và
cả hai writer là `ZipChunkWriter`.

Đã sửa: với `DIM_3D`, chỉ ghi chunk compressed rồi hardlink `original` tới nó.
Bỏ được một lượt zip mỗi chunk. Export vẫn đọc được vì đường dẫn tồn tại.
Nếu filesystem không hỗ trợ hardlink, code tự ghi chunk original như cũ.

Số đo: thời gian worker tạo task 80 cloud, trước 0.788s / 0.516s / 0.510s
(trung vị 0.516s), sau 0.518s / 0.473s / 0.477s (trung vị 0.477s, khoảng 8%).
Đĩa 62M. Export 80 file `.pcd`, 64103576 byte. Task 27 chunk 0 inode `226551`,
link count 2.

## 7. Bỏ process rqscheduler

`cvat_worker_utils` chạy rqworker, rqscheduler, smokescreen và supervisord.
`rqscheduler` import toàn bộ `cvat.asgi` chỉ để poll cron mỗi 30 giây.

Số đo RSS trước khi cắt (`ps`, KB): rqworker 226140, rqscheduler 218288,
supervisord 27836, smokescreen 12928. Tổng 485192 KB. Sau khi cắt:
`ps` không còn `rqscheduler`; cgroup `docker stats` là 188.7 MiB. rqworker vẫn
nghe queue `cleaning`. `--with-scheduler` trên lệnh worker nằm trong
`docker-compose.yml` (không sửa ở đây); đó là heartbeat của RQ, không chạy
5 cron của `rq_scheduler`.

Đã bỏ khỏi `backend_entrypoint.d/cvat.conf` (`["cleaning"]=""`). File này nằm
trong image gốc, nên `docker/Dockerfile.lowram` COPY đè lên. Build còn gỡ CR,
vì bash đọc conf và một checkout Windows (CRLF) làm worker restart với
`Unexpected component`.

Thay bằng cron của host: `scripts/cvat-periodic.ps1` gọi
`django-admin runperiodicjob <job_id>` mỗi giờ cho cả 5 job. Lệnh này gọi hàm
trực tiếp, không cần worker và không cần scheduler. Chạy thừa không hại vì
các hàm idempotent. Đánh đổi: khoảng 5 process Django ngắn mỗi giờ, thay cho
218288 KB thường trú.

5 job phải giữ: clean_up_sessions, cron_export_cache_directory_cleanup,
cron_tmp_directory_cleanup, cron_instance_tmp_directories_cleanup,
clear_unusable_access_tokens.

`cron_tmp_directory_cleanup` dọn `/home/django/data/tmp` (`TMP_FILES_ROOT`),
theo atime, giữ 3 ngày. Probe ở `/tmp` không bị xoá. Probe thư mục
`/home/django/data/tmp/cvat_cleanup_probe` (atime 30 ngày) bị xoá, exit 0.

Nếu cron của host không được cấu hình, tmp và export cache sẽ tăng vô hạn.
