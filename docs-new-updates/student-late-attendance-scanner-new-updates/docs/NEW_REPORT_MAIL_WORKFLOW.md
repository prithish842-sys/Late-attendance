# Report and HOD Mail Workflow

All filters use AND logic.

Example:
Department = CS + Year = 2nd Year + date range => only matching records.

Generate the filtered dataset once and reuse it for preview, Excel, PDF and email attachment.

Default PDF:
`CS_Late_Attendance_<date-range>.pdf`

Optional:
`CS_3rd_Year_<date-range>.pdf`
`CS_2nd_Year_<date-range>.pdf`
`CS_1st_Year_<date-range>.pdf`

Separate year PDFs are technically suitable and should be an optional attachment mode. Combined PDF is the default.

Email:
- formal greeting
- purpose
- department/date range
- 3rd/2nd/1st year student names
- summary
- attachment statement
- formal closing

Flow:
`Send / Forward Report` -> Preview -> Confirm Send -> Mail Provider -> Mail Log.

A direct Gmail compose window is not guaranteed to support programmatic attachment insertion. Reliable implementation is backend/provider sending with generated attachments. A Gmail-client handoff can be treated as an optional integration.
