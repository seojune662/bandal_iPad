import type { MaterialNode } from '../../../../shared/types/materials'
import { STUDY_MARKET_EXTENSIONS } from '../../../../shared/types/studyMarket'

export function isSellableMaterial(path: string): boolean {
  return (STUDY_MARKET_EXTENSIONS as readonly string[]).includes(path.split('.').at(-1)?.toLowerCase() ?? '')
}

export function saleMaterials(nodes: readonly MaterialNode[]): MaterialNode[] {
  return nodes.flatMap(node => node.kind === 'dir'
    ? saleMaterials(node.children ?? [])
    : isSellableMaterial(node.relPath) ? [node] : [])
}

export function initialSaleSelection(files: readonly MaterialNode[], relPath?: string): string[] {
  if (relPath === undefined) return []
  return files.filter(file => file.relPath === relPath).map(file => file.relPath)
}

export function formatWon(amount: number): string {
  return `${new Intl.NumberFormat('ko-KR').format(amount)}원`
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

export function errorMessage(error: unknown): string {
  const message = (error instanceof Error ? error.message : '').replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, '').replace(/^ValidationError:\s*/, '').trim()
  if (/[가-힣]/.test(message) && message.length <= 500) return message
  const errors: Record<string, string> = {
    sign_in_required: '계속하려면 먼저 로그인해 주세요.',
    school_mismatch: '현재 선택한 대학교를 다시 확인해 주세요.',
    school_not_registered: '아직 등록되지 않은 학교예요. 학교 추가를 요청해 주세요.',
    trading_not_ready: '자료 거래를 준비하고 있어요. 임시 저장 후 다시 확인해 주세요.',
    seller_not_ready: '판매자 등록과 본인인증을 먼저 완료해 주세요.',
    seller_not_registered: '판매자 등록을 먼저 완료해 주세요.',
    invalid_price: '가격은 1원부터 10억 원까지 원 단위로 입력해 주세요.',
    invalid_text: '입력한 내용과 글자 수를 확인해 주세요.',
    listing_blocked: '운영자가 확인 중인 자료예요. 판매 관리에서 상태를 확인해 주세요.',
    not_found: '자료를 찾을 수 없어요. 판매가 중지되었을 수 있어요.',
    checkout_expired: '결제 시간이 지났어요. 자료를 다시 선택해 구매해 주세요.',
    files_not_verified: '자료 업로드가 완료되지 않았어요. 다시 저장해 주세요.',
    upload_incomplete: '자료 업로드가 완료되지 않았어요. 다시 시도해 주세요.',
    file_hash_mismatch: '자료의 내용이 달라졌어요. 원본 자료를 다시 선택해 주세요.',
    file_size_mismatch: '자료의 크기가 달라졌어요. 원본 자료를 다시 선택해 주세요.',
    bundle_limit: '자료는 100개, 전체 200 MB, 파일당 50 MB까지 올릴 수 있어요.',
    preview_must_be_image: '미리보기 이미지가 올바르지 않아요. 다시 만들어 주세요.',
    refund_pending: '환불 결과를 확인하고 있어요. 구매 내역에서 다시 확인해 주세요.',
    payment_mismatch: '결제 정보를 확인하지 못했어요. 구매 내역에서 상태를 확인해 주세요.',
    payment_not_found: '확인할 결제가 없어요. 구매 내역을 새로고침해 주세요.',
    immutable_version: '이미 공개된 자료는 수정할 수 없어요. 새 판매 자료를 만들어 주세요.',
    database_request_failed: '처리 중 문제가 생겼어요. 잠시 후 다시 시도해 주세요.'
  }
  const code = message.replace(/^Error:\s*/, '')
  if (errors[code]) return errors[code]
  if (/not.configured|unavailable|disabled|503/i.test(message)) return '마켓플레이스를 준비하고 있어요. 잠시 후 다시 확인해 주세요.'
  if (/unauthor|sign.in|401/i.test(message)) return '계속하려면 먼저 로그인해 주세요.'
  if (/network|fetch|offline/i.test(message)) return '인터넷 연결을 확인하고 다시 시도해 주세요.'
  return '요청을 완료하지 못했어요. 잠시 후 다시 시도해 주세요.'
}

export function sellerProceeds(price: number): number {
  return price - Math.floor(price * 0.1)
}

export function validPrice(value: string): number | null {
  if (!/^\d+$/.test(value.trim())) return null
  const price = Number(value)
  return Number.isSafeInteger(price) && price > 0 && price <= 1_000_000_000 ? price : null
}
