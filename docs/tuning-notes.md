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

`default_settings.py` đọc env, mặc định vẫn 500 MiB nếu không set. `base.py` re-export tên này để `django.conf.settings` thấy trước `AppConfig.ready()`. `docker compose up -d` dùng image `cvat/server:lowram`, trong đó hai file này đã được bake sẵn. Default 64MB nằm trong `docker-compose.yml`.

## 2. Dead config

| Tên | Vì sao chết |
| --- | --- |
| `CVAT_DEFAULT_CHUNK_SIZE` | `task.py` không đọc env. Khi request không gửi `chunk_size`, video bị gán 36. UI chỉ gửi `chunk_size` nếu ô advanced có giá trị (`tasks-actions.ts:252`, `session-implementation.ts:887`). Job tạo không điền ô đó trả `data_chunk_size` 36. |
| `image_quality` | Không có env. UI mặc định 70 tại `advanced-configuration-form.tsx:88` và luôn gửi khi tạo task (`tasks-actions.ts:249`). |
| `CVAT_CONCURRENT_CHUNK_PROCESSING` | `base.py` đã mặc định 1. Ghi thêm 1 trong overlay không đổi hành vi. |

## 3. Đã bác bỏ

| Giả thuyết | Số đo | Kết luận |
| --- | --- | --- |
| Cap cache client = 2 giảm RAM | Sau GC: cap 10 là 1786.3 MB, cap 2 là 1498.0 MB, giảm 288.3 MB. Peak khi cuộn: P10 2027.0, P2 2016.8, chênh 10.2 MB, nhiễu lớn nhất 26.6 MB. | Bác. Source giữ cap 10. |
| Chunk 12 tiết kiệm ~1 GB so với chunk 36, cùng 200 frame | Peak trung vị chunk 36 là 2036.8 MB, chunk 12 là 2016.2 MB, chênh 20.6 MB. | Bác. Mô hình ~1 GB sai. |
| 720p đưa peak 200 frame xuống 1.3–1.5 GB | Peak trung vị 720p là 2437.7 MB, cao hơn 2036.8 MB là 400.9 MB. | Bác. 720p nặng hơn. |
| Sàn ~1 GB là bitmap 1080p | 540p, 200 frame, peak 1955.5 MB. Bitmap 1080p trong cache là 2.07 MB/frame, không phải 8.3 MB. | Bác. Phần khoảng 1.5 GB không theo pixel nguồn. |

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
