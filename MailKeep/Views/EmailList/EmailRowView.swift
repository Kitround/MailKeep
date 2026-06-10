import SwiftUI

struct EmailRowView: View {
    let email: EmailMessage

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email.displaySender)
                    .font(.headline)
                    .lineLimit(1)
                Text(email.subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                if email.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let date = email.date {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
