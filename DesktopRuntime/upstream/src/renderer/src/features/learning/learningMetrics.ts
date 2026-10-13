import type { LearningArticleRef, LearningProjectSnapshot } from '../../../../shared/types/learning'

export type LearningArticleFilter = 'all' | LearningArticleRef['status']
export type LearningArticleDateFilter = 'all' | 'week' | 'month'

export function filterLearningArticles(articles: LearningArticleRef[], status: LearningArticleFilter, date: LearningArticleDateFilter, now = Date.now()): LearningArticleRef[] {
  const days = date === 'week' ? 7 : date === 'month' ? 30 : Infinity
  return articles.filter(article => (status === 'all' || article.status === status)
    && (date === 'all' || Date.parse(article.completedAt ?? article.createdAt) >= now - days * 86_400_000)).reverse()
}

export function learningProgressMetrics(project: LearningProjectSnapshot): { encounteredWordCount: number; latestQuiz: LearningProjectSnapshot['quizAttempts'][number] | undefined; reviewedCardCount: number } {
  return {
    encounteredWordCount: new Set(project.articles.filter(article => article.status === 'completed').flatMap(article => article.matchedWordIds)).size,
    latestQuiz: [...project.quizAttempts].reverse().find(attempt => attempt.completedAt !== null),
    reviewedCardCount: project.cards.filter(card => card.lastReviewedAt !== null).length
  }
}
